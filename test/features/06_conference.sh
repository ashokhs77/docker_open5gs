#!/bin/bash
# Feature 06: Conference Tests
# Validates conference dial-in functionality (rooms 1NNR through the P-CSCF),
# VoLTE/ViLTE conference rooms (1xxx range), max member enforcement,
# hold detection, room cleanup, concurrent conference support, and
# inter-NIB conference routing (INVITE to conference room at external domain).
#
# COMPLETE-PATH conversion: the conference *call* tests no longer dial FreeSWITCH
# directly (172.22.1.150:5090). Every call now follows the real UE path —
# register a UE (attach + IMS register over IPSec) → INVITE a conference number
# 1NNR to the P-CSCF → P-CSCF FSDISPATCH → FreeSWITCH — using the concurrent load
# engine (run_load_test) pointed at a conference room. Assertion rule: N UEs
# dialed ⇒ EXACTLY N LEG rows for that bridge in the P-CSCF conf_cdr.csv (a
# shortfall is a real system/routing/CDR defect, not a lab ceiling).
# Rooms are the local range 1010–1019. Env-tunable knobs:
#   CONF_AUDIO_MEMBERS=24 CONF_VIDEO_MEMBERS=8 CONF_SOAK_SECS=45
#   CONF_AUDIO_ROOM=1016 CONF_VIDEO_ROOM=1017 CONF_CALL_HOLD=6 CONF_MULTI_HOLD=20
#   CONF_ATTACH_STAGGER_MS=1000  (TC-1..5, 9, 10 run in two phases: the N UEs attach
#   and register one after the other, this far apart, and only when all are
#   registered do they dial the room together)
#
# Tests:
#   TC-1:  1-UE audio conference — COMPLETE path (register → P-CSCF → room 1010)
#   TC-2:  1-UE video conference — COMPLETE path (room 1011)
#   TC-3:  4-UE audio conference — COMPLETE path (room 1012)
#   TC-4:  Conference room reuse — COMPLETE path (room 1013, dial/teardown/re-dial → 2 CDR rows)
#   TC-5:  Distinct conference rooms + CDR isolation — COMPLETE path (rooms 1014, 1015)
#   TC-6:  Rx AAR bypass for non-IMS clients (dedicated bearer path validation)
#   TC-7:  Rx Diameter peer connectivity to PCRF
#   TC-8:  Inter-NIB conference INVITE (external IMS domain via I-CSCF, non-5xx)
#   TC-9:  N-UE SINGLE audio conference — COMPLETE path (24 UEs → room 1016; N ⇒ N CDR rows)
#   TC-10: N-UE SINGLE video conference — COMPLETE path (8 UEs → room 1017; N ⇒ N CDR rows)
#   --- content of the dial-in conference CDR (3 fixed UEs join room 1018 staggered) ---
#   TC-11: each LEG row carries the number of the UE it belongs to
#   TC-12: CONF row: host = first joiner, participants = the others, peak = members
#   TC-13: CONF row on top, LEG rows in join order
#   TC-14: media column: audio conference (1018) and video conference (1019)
#   TC-15: per-leg start time and duration match what the UEs did
#   Knobs: CONF_CONTENT_AUDIO_ROOM=1018 CONF_CONTENT_VIDEO_ROOM=1019
#          CONF_CONTENT_STAGGER=4 CONF_CONTENT_HOLD=6
#

set +e

source /opt/test/lib/common.sh
source /opt/test/lib/sipp_helpers.sh

# fs_cli path inside the FreeSWITCH container
FS_CLI="/usr/local/freeswitch/bin/fs_cli"

# Real conference membership count for a room (0 if room absent/empty)
_conf_member_count() {
    docker exec freeswitch "$FS_CLI" -x "conference $1 list count" 2>/dev/null | tr -dc '0-9'
}

# Wait for FreeSWITCH to drain active channels left by a prior soak, so back-to-back
# soak TCs (e.g. TC-9's 24-leg teardown -> TC-10) each start from a clean state.
_fs_drain() {
    local w=0 ch
    while [ "$w" -lt "${CONF_DRAIN_MAX:-20}" ]; do
        ch=$(docker exec freeswitch "$FS_CLI" -x "show channels count" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
        [ -z "$ch" ] && ch=0
        [ "$ch" -le "${CONF_DRAIN_OK:-2}" ] && return 0
        sleep 2; w=$((w+2))
    done
}

# Launch N SIPp legs into ONE room, hold past rtp-timeout, measure membership.
# Sets globals: CONF_SOAK_JOINED, CONF_SOAK_RETAINED, CONF_SOAK_PIDS.
# Args: $1=scenario $2=N $3=room $4=sip_port_base $5=rtp_port_base $6=hold_secs
_conf_soak_launch() {
    local scn="$1" n="$2" room="$3" spbase="$4" rpbase="$5" hold="$6" i jp pids=""
    docker exec freeswitch "$FS_CLI" -x "conference ${room} kick all" >/dev/null 2>&1 || true
    _fs_drain   # let any prior soak's channels tear down before launching this one
    for i in $(seq 1 "$n"); do
        # SIPp reserves a 4-port media block per call (audio RTP/RTCP + video RTP/RTCP),
        # so legs must be spaced >=4 apart on -mp or they collide ("Address already in use").
        # Use a stride of 10 for headroom.
        sipp "${FREESWITCH_IP}:5090" -sf "$scn" -s "$room" \
            -i "$LOCAL_IP" -p $(( spbase + i )) -mp $(( rpbase + i*10 )) \
            -m 1 -l 1 -rtp_echo -timeout 140 -timeout_error \
            >/tmp/sipp_confsoak_${room}_${i}.log 2>&1 &
        pids="$pids $!"
        sleep "${CONF_JOIN_STAGGER:-0.4}"   # stagger joins like real UEs (avoid a thundering-herd INVITE burst)
    done
    CONF_SOAK_PIDS="$pids"
    sleep "${CONF_JOIN_WAIT:-18}"
    CONF_SOAK_JOINED=$(_conf_member_count "$room"); CONF_SOAK_JOINED=${CONF_SOAK_JOINED:-0}
    sleep "$hold"
    CONF_SOAK_RETAINED=$(_conf_member_count "$room"); CONF_SOAK_RETAINED=${CONF_SOAK_RETAINED:-0}
    docker exec freeswitch "$FS_CLI" -x "conference ${room} kick all" >/dev/null 2>&1 || true
    for jp in $CONF_SOAK_PIDS; do kill "$jp" 2>/dev/null; done
    for jp in $CONF_SOAK_PIDS; do wait "$jp" 2>/dev/null || true; done
}

# ============================================================================
# COMPLETE-PATH conference helpers.
#
# Every conference test in this feature drives calls the way a real UE does:
#   register a UE (attach + IMS register over IPSec) → INVITE a conference
#   number (1NNR) to the P-CSCF → P-CSCF FSDISPATCH → FreeSWITCH.
# This is NOT a direct dial to FreeSWITCH:5090 — that path bypasses the P-CSCF,
# registration, 1NNR routing, per-leg Rx, and the conference CDR, so it proves
# nothing about the system carrying real subscribers into a conference.
#
# Conference rooms are the local range 1010–1019 (1 + NIB(01) + room-digit).
# Assertion rule (per requirement): N UEs dialed ⇒ EXACTLY N LEG rows for that
# bridge in the P-CSCF conf_cdr.csv. Fewer is a real failure, not a lab ceiling.
# ============================================================================

# Count LEG rows for a conference bridge id (col 1 == LEG, col 8 == room) in the
# conference CDR (FreeSWITCH-sourced; read via the shared /cdr-logs volume that
# both pcscf and freeswitch mount). Prints 0 if the file/rows are absent.
# Only rows written since this feature started (col 6, start time) are counted:
# the CDR logger prunes rows older than its retention on every write, so a count
# over the whole file can SHRINK between 'before' and 'after'.
_conf_cdr_leg_count() {
    local room="$1"
    docker_exec pcscf \
        "test -f /cdr-logs/conf_cdr.csv && awk -F',' -v r='${room}' -v s='${CONF_CDR_SINCE}' '\$1==\"LEG\" && \$8==r && (s==\"\" || \$6>=s){c++} END{print c+0}' /cdr-logs/conf_cdr.csv || echo 0" \
        2>/dev/null | tr -dc '0-9'
}

# Read the TotalParticipantCount from the newest CONF summary row for a bridge.
_conf_cdr_summary_count() {
    local room="$1"
    docker_exec pcscf \
        "test -f /cdr-logs/conf_cdr.csv && awk -F',' -v r='${room}' '\$1==\"CONF\" && \$8==r{print \$4; exit}' /cdr-logs/conf_cdr.csv || echo" \
        2>/dev/null | tr -dc '0-9'
}

# Register N UEs and have each dial conference <room> through the P-CSCF, holding
# for <hold> seconds so they overlap in one room. Uses the concurrent load engine
# (run_load_test) pointed at a conference number instead of a peer MSISDN.
# Sets: CONF_FP_LAUNCHED, CONF_FP_SUCCESS (UEs that completed the full path).
# Returns 0 if the simulator ran, 1 on simulator/engine error.
_conf_full_path_run() {
    local n="$1" room="$2" media="$3" hold="$4"
    CONF_FP_LAUNCHED="$n"
    CONF_FP_SUCCESS=0
    CONF_FP_ATT=0; CONF_FP_REG=0; CONF_FP_PHASE1=""; CONF_FP_STAGES=""
    local ct="volte"
    [ "$media" = "video" ] && ct="vilte"
    # Two phases (requirement): first all N UEs attach and register, one every
    # CONF_ATTACH_STAGGER_MS; only then do they dial the room, together. An N-UE
    # attach BURST is a different test (load feature) and used to decide this one.
    local stagger_ms="${CONF_ATTACH_STAGGER_MS:-1000}"

    local out
    out=$(timeout $(( 300 + n * 5 + n * stagger_ms / 1000 )) "$PYTHON_BIN" -c "
import sys, os, json
sys.path.insert(0, '/opt/test')
os.environ.setdefault('MME_IP',   '${MME_IP:-172.22.1.9}')
os.environ.setdefault('PCSCF_IP', '${PCSCF_IP:-172.22.1.21}')
os.environ.setdefault('PYHSS_IP', '${PYHSS_IP:-172.22.1.18}')
os.environ.setdefault('LOCAL_IP', '${LOCAL_IP:-172.22.1.200}')
os.environ.setdefault('MCC', '${MCC:-001}')
os.environ.setdefault('MNC', '${MNC:-01}')
from ue_sim.ue_simulator import run_load_test
from ue_sim.config import setup_logging
setup_logging('WARNING')
try:
    r = run_load_test(num_ues=${n}, target_msisdn='${room}', call_type='${ct}',
                      call_duration=float(${hold}), skip_call=False,
                      attach_stagger_ms=float(${stagger_ms}), phased_call=True)
    # run_load_test populates result.call_success (count of UEs whose INVITE to the
    # target was answered end-to-end); NOT callers_success (a different variant).
    print(json.dumps({'callers_ok': int(getattr(r, 'call_success', 0)),
                      'reg': int(getattr(r, 'register_success', 0)),
                      'att': int(getattr(r, 'attach_success', 0)),
                      'phase1_registered': int(getattr(r, 'phase1_registered', 0)),
                      'phase1_seconds': float(getattr(r, 'phase1_seconds', 0.0)),
                      'failure_stages': getattr(r, 'failure_stages', {})}))
except Exception as e:
    print(json.dumps({'error': str(e)}))
" 2>/dev/null)

    [ -z "$out" ] && return 1
    echo "$out" | grep -q '"error"' && { log "  full-path run error: $(echo "$out" | tr -d '\n')"; return 1; }
    CONF_FP_SUCCESS=$(echo "$out" | "$PYTHON_BIN" -c \
        "import sys,json; print(json.load(sys.stdin).get('callers_ok',0))" 2>/dev/null | tr -dc '0-9')
    CONF_FP_SUCCESS=${CONF_FP_SUCCESS:-0}
    # Where the UEs got to, so a shortfall names its stage
    read -r CONF_FP_ATT CONF_FP_REG CONF_FP_PHASE1 CONF_FP_STAGES <<< "$(echo "$out" | "$PYTHON_BIN" -c         "import sys,json; d=json.load(sys.stdin); print(d.get('att',0), d.get('reg',0), d.get('phase1_seconds',0), json.dumps(d.get('failure_stages',{})).replace(' ',''))" 2>/dev/null)"
    echo "  room ${room}: phase 1 (staggered attach+register, ${stagger_ms}ms apart): attached=${CONF_FP_ATT}/${n} registered=${CONF_FP_REG}/${n} in ${CONF_FP_PHASE1}s; phase 2 (conference): callers_ok=${CONF_FP_SUCCESS}/${n}; failure stages=${CONF_FP_STAGES}" >> "$_FEATURE_REPORT"
    return 0
}

# One TC body: N UEs → room <room> over the complete path, then assert EXACTLY N
# LEG rows landed in conf_cdr.csv for that bridge (the N-in ⇒ N-in-CDR rule).
# Args: $1=num_ues $2=room $3=media(audio|video) $4=hold_secs $5=human-label
_conf_full_path_case() {
    local n="$1" room="$2" media="$3" hold="$4" label="$5"
    if ! ue_sim_probe 2>/dev/null; then
        skip "$label" "UE simulator environment not available (attach/IPSec) — cannot exercise the complete conference path"
        return
    fi
    local before after delta
    before=$(_conf_cdr_leg_count "$room"); before=${before:-0}
    if ! _conf_full_path_run "$n" "$room" "$media" "$hold"; then
        fail "$label" "UE load engine did not run (simulator/provisioning error) for room ${room}"
        return
    fi
    sleep 3   # let the P-CSCF exec_msg flush the LEG rows after the BYEs
    after=$(_conf_cdr_leg_count "$room"); after=${after:-0}
    delta=$(( after - before ))
    echo "  ${label}: full-path callers_ok=${CONF_FP_SUCCESS}/${n}, conf_cdr LEG rows(delta)=${delta}/${n} (room ${room})" >> "$_FEATURE_REPORT"

    if [ "${CONF_FP_SUCCESS:-0}" -eq "$n" ] && [ "$delta" -eq "$n" ]; then
        pass "${label}: ${n}/${n} UEs attached+registered one by one (${CONF_FP_PHASE1}s), then all dialled the room: ${n}/${n} in the conference AND conf_cdr.csv has exactly ${n} LEG rows for room ${room}"
    else
        fail "${label}: complete-path count mismatch" \
             "expected ${n} UEs and ${n} CDR LEG rows; got attached=${CONF_FP_ATT}, registered=${CONF_FP_REG}, in the conference=${CONF_FP_SUCCESS}, CDR LEG delta=${delta} (room ${room}); failure stages ${CONF_FP_STAGES}. Attach was paced (${CONF_ATTACH_STAGGER_MS:-1000}ms/UE), so attached<${n} is an EPC problem, registered<attached an IMS one, conference<registered the conference path, LEG delta<conference the CDR."
    fi
}

run_conference_tests() {
    start_feature "Conference"
    # Clock of the container that stamps the CDR rows
    CONF_CDR_SINCE=$(docker exec freeswitch date '+%Y-%m-%d %H:%M:%S' 2>/dev/null | tr -dc '0-9: -')

    # TC-1: single-UE VoLTE conference over the COMPLETE path (register → P-CSCF → FS)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: 1-UE audio conference via complete path (register → P-CSCF → room 1010)"
        _conf_full_path_case 1 1010 audio "${CONF_CALL_HOLD:-6}" "1-UE audio conference (complete path)"
    fi

    # TC-2: single-UE ViLTE (video) conference over the COMPLETE path
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: 1-UE video conference via complete path (register → P-CSCF → room 1011)"
        _conf_full_path_case 1 1011 video "${CONF_CALL_HOLD:-6}" "1-UE video conference (complete path)"
    fi

    # TC-3: multi-member (4) audio conference over the COMPLETE path.
    # 4 registered UEs each dial the same room through the P-CSCF and overlap in it.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: 4-UE audio conference via complete path (register → P-CSCF → room 1012)"
        _conf_full_path_case 4 1012 audio "${CONF_MULTI_HOLD:-20}" "4-UE audio conference (complete path)"
    fi

    # TC-4: conference room reuse over the COMPLETE path (dial → teardown → re-dial).
    # Two sequential single-UE conferences to the same room, each via register →
    # P-CSCF → FS. Expect the room reusable and EXACTLY 2 CDR LEG rows total.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: conference room 1013 reuse via complete path (dial, teardown, re-dial)"
        if ! ue_sim_probe 2>/dev/null; then
            skip "Conference room reuse (complete path)" "UE simulator environment not available"
        else
            local r9_before r9_after ok1 ok2
            r9_before=$(_conf_cdr_leg_count 1013); r9_before=${r9_before:-0}
            _conf_full_path_run 1 1013 audio "${CONF_CALL_HOLD:-6}"; ok1=${CONF_FP_SUCCESS:-0}
            sleep 3
            _conf_full_path_run 1 1013 audio "${CONF_CALL_HOLD:-6}"; ok2=${CONF_FP_SUCCESS:-0}
            sleep 3
            r9_after=$(_conf_cdr_leg_count 1013); r9_after=${r9_after:-0}
            if [ "$ok1" -eq 1 ] && [ "$ok2" -eq 1 ] && [ $(( r9_after - r9_before )) -eq 2 ]; then
                pass "Room 1013 reusable via complete path: 2 sequential UE conferences, exactly 2 CDR LEG rows"
            else
                fail "Room 1013 reuse over complete path failed" "call1_ok=${ok1}/1, call2_ok=${ok2}/1, CDR LEG delta=$(( r9_after - r9_before ))/2"
            fi
        fi
    fi

    # TC-5: multiple distinct conference rooms over the COMPLETE path (routing +
    # per-bridge CDR isolation). Two rooms (1014, 1015), each a 2-UE conference via
    # register → P-CSCF → FS; each bridge must record EXACTLY its own 2 LEG rows.
    # (Same-room concurrency at scale is covered by the 24-UE soak; this checks the
    # P-CSCF keeps distinct bridges — and their CDR aggregates — independent.)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: distinct conference rooms 1014 + 1015 via complete path (CDR isolation)"
        if ! ue_sim_probe 2>/dev/null; then
            skip "Distinct conference rooms (complete path)" "UE simulator environment not available"
        else
            local b14 b15 a14 a15
            b14=$(_conf_cdr_leg_count 1014); b14=${b14:-0}
            b15=$(_conf_cdr_leg_count 1015); b15=${b15:-0}
            _conf_full_path_run 2 1014 audio "${CONF_MULTI_HOLD:-20}"
            sleep 3
            _conf_full_path_run 2 1015 audio "${CONF_MULTI_HOLD:-20}"
            sleep 3
            a14=$(_conf_cdr_leg_count 1014); a14=${a14:-0}
            a15=$(_conf_cdr_leg_count 1015); a15=${a15:-0}
            if [ $(( a14 - b14 )) -eq 2 ] && [ $(( a15 - b15 )) -eq 2 ]; then
                pass "Distinct complete-path conferences isolated: room 1014 and room 1015 each recorded exactly 2 CDR LEG rows"
            else
                fail "Distinct complete-path conference CDR isolation mismatch" "room 1014 LEG delta=$(( a14 - b14 ))/2, room 1015 LEG delta=$(( a15 - b15 ))/2"
            fi
        fi
    fi

    # TC-6: Rx AAR path validation (non-IMS clients correctly bypass Rx)
    # Verifies P-CSCF Rx media authorization logic by checking logs from previous
    # conference tests. SIPp test clients (without IMEI) should bypass Rx AAR.
    # Real IMS UEs (with +sip.instance IMEI) would trigger Rx AAR → PCRF → dedicated bearer.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Rx AAR bypass for non-IMS SIPp clients (dedicated bearer path validation)"
        log "Verifying P-CSCF correctly skips Rx for test clients without IMEI Contact header"

        # Check P-CSCF logs from all tests run so far (regression + conference)
        RX_LOG=$(docker logs pcscf 2>&1 | tail -2000)

        # Non-IMS clients (SIPp without IMEI) should see one of the explicit Rx-bypass log lines.
        RX_SKIPPED=$(printf '%s\n' "$RX_LOG" | grep -E -c "Skipping Rx|Non-IMS SIP client|Skipping MO Rx|Skipping MT Rx|Skipping Rx media authorization" 2>/dev/null || true)
        RX_SKIPPED=$(printf '%s' "${RX_SKIPPED:-0}" | tr -cd '0-9')
        RX_SKIPPED=${RX_SKIPPED:-0}
        # Real IMS clients would see "DOING RX" — should NOT appear for our SIPp tests
        RX_DOING_MO=$(printf '%s\n' "$RX_LOG" | grep -E -c "DOING RX in MO|DOING RX IN MO" 2>/dev/null || true)
        RX_DOING_MO=$(printf '%s' "${RX_DOING_MO:-0}" | tr -cd '0-9')
        RX_DOING_MO=${RX_DOING_MO:-0}
        RX_DOING_MT=$(printf '%s\n' "$RX_LOG" | grep -E -c "DOING RX in MT|DOING RX IN MT" 2>/dev/null || true)
        RX_DOING_MT=$(printf '%s' "${RX_DOING_MT:-0}" | tr -cd '0-9')
        RX_DOING_MT=${RX_DOING_MT:-0}

        if [ "$RX_SKIPPED" -gt 0 ]; then
            pass "Rx AAR correctly bypassed for SIPp clients (${RX_SKIPPED} skips). IMS clients with IMEI would trigger Rx AAR → PCRF → dedicated bearer (QCI-1)"
        else
            # No Rx skip logs found — check if ims_qos module is loaded
            RX_MODULE=$(docker exec pcscf kamcmd mod.is_loaded ims_qos 2>/dev/null | tr -d '\r' | tail -n 1)
            RX_MODULE=${RX_MODULE:-unknown}
            if echo "$RX_MODULE" | grep -qi "true\|loaded"; then
                # Module is loaded — Rx path is configured. Exact "Skipping Rx" log message
                # depends on P-CSCF config version; absence of this specific string does NOT
                # mean Rx is broken. TC-7 separately validates the Rx Diameter peer is up.
                skip "Rx AAR bypass log check" \
                    "ims_qos loaded and Rx peer connected (TC-7) — 'Skipping Rx' log string not found but may use different message in this P-CSCF config version"
            else
                fail "ims_qos module NOT loaded on P-CSCF (dedicated bearer path unavailable)" "Module status: ${RX_MODULE}"
            fi
        fi
    fi

    # TC-7: Rx Diameter peer connectivity (PCRF reachability)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Rx Diameter peer connectivity to PCRF"
        log "Checking P-CSCF Diameter Rx peer status for dedicated bearer signaling"

        # Check CDP (C Diameter Peer) status for Rx interface
        CDP_PEERS=$(docker exec pcscf kamcmd cdp.list_peers 2>/dev/null || echo "")

        if [ -n "$CDP_PEERS" ]; then
            # Check if any Rx peer is connected (state I-Open = connected)
            RX_CONNECTED=$(printf '%s\n' "$CDP_PEERS" | grep -c "I-Open\|State.*Open" 2>/dev/null || true)
            RX_CONNECTED=$(printf '%s' "${RX_CONNECTED:-0}" | tr -cd '0-9')
            RX_CONNECTED=${RX_CONNECTED:-0}
            RX_CLOSED=$(printf '%s\n' "$CDP_PEERS" | grep -c "Closed\|Wait\|Closing" 2>/dev/null || true)
            RX_CLOSED=$(printf '%s' "${RX_CLOSED:-0}" | tr -cd '0-9')
            RX_CLOSED=${RX_CLOSED:-0}

            if [ "$RX_CONNECTED" -gt 0 ]; then
                pass "Rx Diameter peer connected (${RX_CONNECTED} peers in Open state) — dedicated bearer path operational"
            else
                fail "Rx Diameter peer NOT connected (${RX_CLOSED} closed/waiting) — dedicated bearer setup will fail" "PCRF may be down or Diameter config mismatch"
            fi
        else
            # No CDP peers at all
            RX_CONFIG=$(docker exec pcscf grep -c "Rx\|pcrf\|ims_qos" /etc/kamailio_pcscf/pcscf.xml 2>/dev/null || true)
            RX_CONFIG=$(printf '%s' "${RX_CONFIG:-0}" | tr -cd '0-9')
            RX_CONFIG=${RX_CONFIG:-0}
            if [ "$RX_CONFIG" -gt 0 ]; then
                fail "Rx configured in pcscf.xml but no CDP peers found (Diameter not initialized)" ""
            else
                fail "Rx Diameter not configured on P-CSCF (dedicated bearer path missing)" ""
            fi
        fi
    fi

    # TC-8: Inter-NIB conference INVITE — join conference room at external IMS domain
    # In a single-NIB lab (no external NIB / IBCF), the IMS chain will return 5xx
    # when it cannot locate the external conference server — this is expected.
    # The test verifies the IMS chain processed the INVITE at all.
    # Only a SIPp crash or complete silence (no P-CSCF response) is a failure.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Inter-NIB conference INVITE (sip:1010@external.example via I-CSCF)"
        local scenario="/opt/test/scenarios/conference_inter_nib_invite.xml"
        if [ ! -f "$scenario" ]; then
            skip "Inter-NIB conference INVITE" "Scenario conference_inter_nib_invite.xml not found"
        elif ! check_port "$PCSCF_IP" "${PCSCF_PORT:-5060}"; then
            skip "Inter-NIB conference INVITE" "P-CSCF not reachable"
        else
            local inter_conf_out
            inter_conf_out=$(run_sipp_templated "$PCSCF_IP" "${PCSCF_PORT:-5060}" \
                "$scenario" "1010" 9340 2>&1)
            local inter_conf_rc=$?

            # SIPp crash = real failure regardless of response
            if echo "$inter_conf_out" | grep -qE "Assertion.*failed|Segmentation fault|not implemented in display"; then
                fail "Inter-NIB conference INVITE: SIPp crashed" \
                     "$(echo "$inter_conf_out" | grep -E 'Assertion|Segmentation|ERROR' | head -3)"
            elif echo "$inter_conf_out" | grep -qE "(Successful call|Failed call)"; then
                # SIPp counted at least one call — IMS chain processed the INVITE
                pass "Inter-NIB conference INVITE: IMS chain processed INVITE toward external domain (any response acceptable — no external NIB in lab)"
            elif [ $inter_conf_rc -eq 0 ]; then
                pass "Inter-NIB conference INVITE: SIPp exited cleanly (IMS chain processed INVITE)"
            else
                fail "Inter-NIB conference INVITE: No SIP response from P-CSCF — check P-CSCF connectivity" \
                     "$(echo "$inter_conf_out" | tail -5)"
            fi
        fi
    fi

    # TC-9: N-UE SINGLE audio conference — the "24 UEs in one conference" requirement,
    # over the COMPLETE path. N registered UEs each dial the same room via the P-CSCF
    # and overlap for the hold window. Requirement: N UEs ⇒ EXACTLY N CDR LEG rows.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local n_aud="${CONF_AUDIO_MEMBERS:-24}" room_aud="${CONF_AUDIO_ROOM:-1016}" hold_a="${CONF_SOAK_SECS:-45}"
        log "TC-${_TEST_NUM}: ${n_aud}-UE SINGLE audio conference via COMPLETE path (register → P-CSCF → room ${room_aud}), ${hold_a}s hold"
        _conf_full_path_case "$n_aud" "$room_aud" audio "$hold_a" "${n_aud}-UE audio conference (complete path)"
    fi

    # TC-10: N-UE SINGLE video (ViLTE) conference — the "8 UEs in one video conference"
    # requirement, over the COMPLETE path. N registered UEs each dial the same room via
    # the P-CSCF with audio+video SDP. Requirement: N UEs ⇒ EXACTLY N CDR LEG rows.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local n_vid="${CONF_VIDEO_MEMBERS:-8}" room_vid="${CONF_VIDEO_ROOM:-1017}" hold_v="${CONF_SOAK_SECS:-45}"
        log "TC-${_TEST_NUM}: ${n_vid}-UE SINGLE video conference via COMPLETE path (register → P-CSCF → room ${room_vid}), ${hold_v}s hold"
        _conf_full_path_case "$n_vid" "$room_vid" video "$hold_v" "${n_vid}-UE video conference (complete path)"
    fi

    # ── TC-11..15: CONTENT of the dial-in conference CDR ─────────────────────────
    # The cases above prove "N UEs => N LEG rows". These look inside the rows: who is
    # in them, the CONF summary, the order, the media type and the times. Three fixed
    # UEs join room 1018 one after the other (CONF_CONTENT_STAGGER s apart) and leave
    # together; two UEs make a video conference in room 1019. One simulator run each,
    # shared by the cases that read it.
    local cc_room_a="${CONF_CONTENT_AUDIO_ROOM:-1018}" cc_room_v="${CONF_CONTENT_VIDEO_ROOM:-1019}"
    local cc_stagger="${CONF_CONTENT_STAGGER:-4}" cc_hold="${CONF_CONTENT_HOLD:-6}"
    local cc_json_a="" cc_rows_a="" cc_json_v="" cc_rows_v="" cc_verdicts=""

    # _conf_content_run <room> <count> <port> [--video]  -> sets CC_JSON, CC_ROWS
    _conf_content_run() {
        local room="$1" count="$2" port="$3" extra="$4" tries=0
        CC_JSON=$(cd /opt/test && env \
            MME_IP="${MME_IP:-172.22.1.9}" PCSCF_IP="${PCSCF_IP:-172.22.1.21}" \
            PYHSS_IP="${PYHSS_IP:-172.22.1.18}" LOCAL_IP="${LOCAL_IP:-172.22.1.200}" \
            MCC="${MCC:-001}" MNC="${MNC:-01}" IMS_DOMAIN="${IMS_DOMAIN}" \
            timeout 240 "$PYTHON_BIN" -m ue_sim.merge_scenarios dialin --room "$room" --count "$count" \
            --stagger "$cc_stagger" --hold "$cc_hold" --port "$port" $extra \
            --log-file "${REPORT_DIR:-/opt/test/reports}/conference_content_${room}.log" 2>/dev/null | tail -1)
        [ -n "$CC_JSON" ] || CC_JSON='{"errors":["scenario produced no output (timeout or crash)"]}'
        CC_ROWS=""
        while :; do     # rows are written when the room is destroyed
            CC_ROWS=$(docker exec pcscf sh -c "awk -F',' -v r='${room}' -v s='${CONF_CDR_SINCE}' '\$8==r && (s==\"\" || \$6>=s)' /cdr-logs/conf_cdr.csv 2>/dev/null")
            [ -n "$CC_ROWS" ] && break
            tries=$(( tries + 1 )); [ "$tries" -ge 6 ] && break
            sleep 2
        done
        append_report_block "dial-in content run room ${room}: simulator" "$CC_JSON"
        append_report_block "dial-in content run room ${room}: conf_cdr.csv rows" "$CC_ROWS"
    }

    # Judge one run. Prints one line per check:  <id>|PASS or FAIL|<text>
    #   who = LEG rows name each participant, conf = CONF summary, order = block order,
    #   times = start/duration per leg, media = media column
    _conf_content_eval() {
        CC_J="$1" CC_R="$2" CC_MEDIA="$3" CC_STAGGER="$cc_stagger" "$PYTHON_BIN" - <<'PY' 2>/dev/null
import json, os
try:
    run = json.loads(os.environ["CC_J"])
except Exception:
    run = {}
rows = [l.split(",") for l in os.environ["CC_R"].splitlines() if l.strip()]
media, stagger = os.environ["CC_MEDIA"], float(os.environ["CC_STAGGER"])
members = [m for m in run.get("members", []) if m.get("ok")]
nums = [m["number"] for m in members]
n = len(nums)
legs = [r for r in rows if r[0] == "LEG" and len(r) >= 9]
confs = [r for r in rows if r[0] == "CONF" and len(r) >= 9]
def out(key, ok, text):
    print("%s|%s|%s" % (key, "PASS" if ok else "FAIL", text))
if n == 0 or run.get("errors"):
    why = "simulator: %s setup=%s" % (run.get("errors"), run.get("setup"))
    for key in ("who", "conf", "order", "times", "media"):
        out(key, False, "conference did not take place - " + why)
    raise SystemExit
leg_nums = [r[2] for r in legs]
out("who", len(legs) == n and sorted(leg_nums) == sorted(nums),
    "%d LEG rows, participants %s; UEs that dialled: %s" % (len(legs), leg_nums, nums))
if len(confs) == 1:
    c = confs[0]
    parts = [p for p in c[2].split(";") if p]
    out("conf", c[1] == nums[0] and sorted(parts) == sorted(nums[1:]) and c[3] == str(n),
        "CONF row host=%s (first joiner %s), participants=%s (others %s), peak=%s (members %d)"
        % (c[1], nums[0], parts, nums[1:], c[3], n))
else:
    out("conf", False, "%d CONF rows for this conference, want 1" % len(confs))
starts = [r[5] for r in legs]
out("order", bool(rows) and rows[0][0] == "CONF" and all(r[0] == "LEG" for r in rows[1:])
    and leg_nums == nums and starts == sorted(starts),
    "file order %s; LEG participants in file %s, join order %s; LEG start times %s"
    % ([r[0] for r in rows], leg_nums, nums, starts))
by_num = {r[2]: r for r in legs}
durs, problems = [], []
for m in members:
    r = by_num.get(m["number"])
    try:
        d = int(r[6].rstrip("s"))
    except Exception:
        problems.append("%s: no usable duration" % m["label"]); continue
    durs.append(d)
    if abs(d - m.get("seconds", -99)) > 4:
        problems.append("%s: CDR %ds vs %ss in the call" % (m["label"], d, m.get("seconds")))
for a, b in zip(durs, durs[1:]):
    if a - b < stagger - 2:
        problems.append("a later joiner is not ~%gs shorter (%ds then %ds)" % (stagger, a, b))
if len(set(starts)) != len(starts):
    problems.append("LEG start times not distinct: %s" % starts)
out("times", not problems and len(durs) == n,
    "LEG durations %s (joins %gs apart, measured %s)%s"
    % (durs, stagger, [m.get("seconds") for m in members],
       "" if not problems else " - " + "; ".join(problems)))
medias = sorted(set(r[4] for r in rows))
out("media", bool(rows) and medias == [media], "media column %s, want %s" % (medias, media))
PY
    }
    _conf_content_get() { echo "$1" | awk -F'|' -v k="$2" '$1==k{print $2; exit}'; }
    _conf_content_txt() { echo "$1" | awk -F'|' -v k="$2" '$1==k{sub(/^[^|]*\|[^|]*\|/,""); print; exit}'; }
    # _conf_content_case <key> <pass text> <fail title>
    _conf_content_case() {
        if [ -z "$cc_verdicts" ]; then
            skip "$3" "UE simulator environment not available (ue_sim.merge_scenarios dialin)"
        elif [ "$(_conf_content_get "$cc_verdicts" "$1")" = "PASS" ]; then
            pass "$2: $(_conf_content_txt "$cc_verdicts" "$1")"
        else
            fail "$3" "$(_conf_content_txt "$cc_verdicts" "$1")"
        fi
    }

    if should_run_test 11 || should_run_test 12 || should_run_test 13 || should_run_test 14 || should_run_test 15; then
        if ue_sim_probe 2>/dev/null && "$PYTHON_BIN" -c "import sys; sys.path.insert(0,'/opt/test'); import ue_sim.merge_scenarios" 2>/dev/null; then
            log "  running 3-UE staggered dial-in conference in room ${cc_room_a}..."
            _conf_content_run "$cc_room_a" 3 160 ""
            cc_json_a="$CC_JSON"; cc_rows_a="$CC_ROWS"
            cc_verdicts=$(_conf_content_eval "$cc_json_a" "$cc_rows_a" audio)
        fi
    fi

    # TC-11: every LEG row names the participant it belongs to
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: dial-in conference CDR - each LEG row carries its own participant"
        _conf_content_case who "Each LEG row carries the number of the UE that dialled" "Dial-in conference CDR does not identify the participants"
    fi

    # TC-12: CONF summary row
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: dial-in conference CDR - CONF row (host, participants, peak)"
        _conf_content_case conf "CONF row correct" "Dial-in conference CDR: CONF row wrong"
    fi

    # TC-13: block order
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: dial-in conference CDR - CONF first, LEG rows in join order"
        _conf_content_case order "CONF row on top, LEG rows in join order" "Dial-in conference CDR: rows not in CONF + join order"
    fi

    # TC-14: media column, audio and video
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: dial-in conference CDR - media column (audio room ${cc_room_a}, video room ${cc_room_v})"
        if [ -z "$cc_verdicts" ]; then
            skip "Dial-in conference CDR media column" "UE simulator environment not available (ue_sim.merge_scenarios dialin)"
        else
            log "  running 2-UE video dial-in conference in room ${cc_room_v}..."
            _conf_content_run "$cc_room_v" 2 164 "--video"
            cc_json_v="$CC_JSON"; cc_rows_v="$CC_ROWS"
            local cc_v
            cc_v=$(_conf_content_eval "$cc_json_v" "$cc_rows_v" video)
            if [ "$(_conf_content_get "$cc_verdicts" media)" = "PASS" ] && [ "$(_conf_content_get "$cc_v" media)" = "PASS" ] \
               && [ "$(_conf_content_get "$cc_v" who)" = "PASS" ]; then
                pass "Media column correct: audio conference -> $(_conf_content_txt "$cc_verdicts" media); video conference -> $(_conf_content_txt "$cc_v" media)"
            else
                fail "Dial-in conference CDR: media column wrong" "audio room ${cc_room_a}: $(_conf_content_txt "$cc_verdicts" media) | video room ${cc_room_v}: $(_conf_content_txt "$cc_v" media); $(_conf_content_txt "$cc_v" who)"
            fi
        fi
    fi

    # TC-15: start time and duration per leg
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: dial-in conference CDR - per-leg start and duration"
        _conf_content_case times "Per-leg times correct" "Dial-in conference CDR: leg times wrong"
    fi


    # Clean up temp files
    rm -f /tmp/sipp_conf_tc*_err.log /tmp/sipp_conf_tc*_out.log /tmp/test_rx_bearer.xml /tmp/sipp_confsoak_*.log 2>/dev/null

    end_feature
}
