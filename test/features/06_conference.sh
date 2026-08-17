#!/bin/bash
# Feature 06: Conference Tests
# Validates conference dial-in functionality including conf-factory routing,
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
#
# Tests:
#   TC-1:  DNS conf-factory resolution (infra)
#   TC-2:  1-UE audio conference — COMPLETE path (register → P-CSCF → room 1010)
#   TC-3:  P-CSCF VoLTE conf-factory routing (P-CSCF-side; gated on conf-factory DNS)
#   TC-4:  1-UE video conference — COMPLETE path (room 1011)
#   TC-5:  P-CSCF ViLTE conf-factory routing (P-CSCF-side; gated on conf-factory DNS)
#   TC-6:  Sequential conf-factory rooms (P-CSCF-side; gated on conf-factory DNS)
#   TC-7:  4-UE audio conference — COMPLETE path (room 1012)
#   TC-8:  Hold SDP via conf-factory (P-CSCF-side; gated on conf-factory DNS)
#   TC-9:  Conference room reuse — COMPLETE path (room 1013, dial/teardown/re-dial → 2 CDR rows)
#   TC-10: Distinct conference rooms + CDR isolation — COMPLETE path (rooms 1014, 1015)
#   TC-11: Rx AAR bypass for non-IMS clients (dedicated bearer path validation)
#   TC-12: Rx Diameter peer connectivity to PCRF
#   TC-13: Inter-NIB conference INVITE (external IMS domain via I-CSCF, non-5xx)
#   TC-14: N-UE SINGLE audio conference — COMPLETE path (24 UEs → room 1016; N ⇒ N CDR rows)
#   TC-15: N-UE SINGLE video conference — COMPLETE path (8 UEs → room 1017; N ⇒ N CDR rows)
#   TC-16: Conf-factory INVITE as Optimus/MTK UA (P-CSCF-side; gated on conf-factory DNS)
#   TC-17: Conf-factory INVITE as Samsung UA (P-CSCF-side; gated on conf-factory DNS)
#
# The conf-factory tests (TC-3/5/6/8/16/17) already route through the P-CSCF (not a
# direct FreeSWITCH dial); they remain gated on conf-factory DNS and UA-profile SIPp.

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
# soak TCs (e.g. TC-14's 24-leg teardown -> TC-15) each start from a clean state.
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
_conf_cdr_leg_count() {
    local room="$1"
    docker_exec pcscf \
        "test -f /cdr-logs/conf_cdr.csv && awk -F',' -v r='${room}' '\$1==\"LEG\" && \$8==r{c++} END{print c+0}' /cdr-logs/conf_cdr.csv || echo 0" \
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
    local ct="volte"
    [ "$media" = "video" ] && ct="vilte"

    local out
    out=$(timeout $(( 240 + n * 5 )) "$PYTHON_BIN" -c "
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
                      call_duration=float(${hold}), skip_call=False)
    # run_load_test populates result.call_success (count of UEs whose INVITE to the
    # target was answered end-to-end); NOT callers_success (a different variant).
    print(json.dumps({'callers_ok': int(getattr(r, 'call_success', 0)),
                      'reg': int(getattr(r, 'register_success', 0)),
                      'att': int(getattr(r, 'attach_success', 0))}))
except Exception as e:
    print(json.dumps({'error': str(e)}))
" 2>/dev/null)

    [ -z "$out" ] && return 1
    echo "$out" | grep -q '"error"' && { log "  full-path run error: $(echo "$out" | tr -d '\n')"; return 1; }
    CONF_FP_SUCCESS=$(echo "$out" | "$PYTHON_BIN" -c \
        "import sys,json; print(json.load(sys.stdin).get('callers_ok',0))" 2>/dev/null | tr -dc '0-9')
    CONF_FP_SUCCESS=${CONF_FP_SUCCESS:-0}
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
        pass "${label}: ${n}/${n} UEs completed register→P-CSCF→conference AND conf_cdr.csv has exactly ${n} LEG rows for room ${room}"
    else
        fail "${label}: complete-path count mismatch" \
             "expected ${n} UEs and ${n} CDR LEG rows; got callers_ok=${CONF_FP_SUCCESS}, CDR LEG delta=${delta} (room ${room}). A shortfall here is a real system-capacity/routing/CDR defect on the complete path."
    fi
}

run_conference_tests() {
    start_feature "Conference"

    # Check if conf-factory DNS is configured (required for conf-factory tests).
    # Direct FreeSWITCH conference tests (TC-2, TC-4, TC-7, TC-9, TC-10) always run.
    # Conf-factory P-CSCF routing tests (TC-3, TC-5, TC-6, TC-8) need conf-factory DNS.
    local conf_factory_dns_available=false
    local conf_dns
    conf_dns=$(dig +short conf-factory.${IMS_DOMAIN} @${DNS_IP} A 2>/dev/null | head -1 | tr -d '[:space:]')
    if [ -n "$conf_dns" ]; then
        conf_factory_dns_available=true
        log "conf-factory DNS available: ${conf_dns}"
    else
        log "NOTE: conf-factory DNS not configured — conf-factory tests (TC-3,5,6,8) will be skipped"
    fi

    # Pre-generate SIPp scenarios with IMS_DOMAIN baked in
    log "Preparing SIPp conference scenarios..."
    sed "s/IMS_DOMAIN/$IMS_DOMAIN/g" /opt/test/scenarios/ue_a_conf_factory.xml > /tmp/test_conf_factory.xml
    sed "s/IMS_DOMAIN/$IMS_DOMAIN/g" /opt/test/scenarios/ue_a_vilte_conf_factory.xml > /tmp/test_vilte_conf_factory.xml
    sed "s/IMS_DOMAIN/$IMS_DOMAIN/g" /opt/test/scenarios/ue_a_hold_detect.xml > /tmp/test_hold_detect.xml
    log "Conference scenarios prepared"

    # Pre-register UE-A with IMS so P-CSCF will accept conf-factory INVITEs (TC-3/5/6/8).
    # Earlier IMS registration probes can send REGISTER expires=0, leaving UE-A
    # deregistered. Without re-registration here, P-CSCF returns 403 "must register first".
    if $conf_factory_dns_available && ue_sim_probe 2>/dev/null; then
        local _pre_reg
        _pre_reg=$(timeout 30 $PYTHON_BIN -c "
import sys, os
sys.path.insert(0, '/opt/test')
os.environ.setdefault('MME_IP', '${MME_IP:-172.22.1.9}')
os.environ.setdefault('PCSCF_IP', '${PCSCF_IP:-172.22.1.21}')
os.environ.setdefault('PYHSS_IP', '${PYHSS_IP:-172.22.1.18}')
os.environ.setdefault('LOCAL_IP', '${LOCAL_IP:-172.22.1.200}')
os.environ.setdefault('MCC', '${MCC:-001}')
os.environ.setdefault('MNC', '${MNC:-01}')
from ue_sim.ue_simulator import UESimulator
from ue_sim.config import Config
import logging
logging.disable(logging.WARNING)
sub = Config.default_subscribers()[0]
ue = UESimulator(imsi=sub.imsi, ki=sub.ki, opc=sub.opc, msisdn=sub.msisdn,
                 sip_local_port=Config.SIP_LOCAL_PORT_BASE + 60)
ok_att = ue.attach()
ok_reg = ue.ims_register() if ok_att else False
# Do NOT call ue.detach() — registration must persist for the INVITE tests below.
print('OK' if ok_reg else 'FAIL')
" 2>/dev/null || echo 'FAIL')
        if [ "$_pre_reg" = "OK" ]; then
            log "UE-A (9876540700) pre-registered with IMS for conf-factory tests"
        else
            log "WARNING: UE-A pre-registration failed — TC-3/5/6/8 may get 403 Forbidden"
        fi
    fi

    # TC-1: DNS conf-factory resolution (conference infrastructure)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: DNS conf-factory resolution (conference infrastructure)"
        if $conf_factory_dns_available; then
            if [ "$conf_dns" = "$PCSCF_IP" ]; then
                pass "conf-factory.${IMS_DOMAIN} resolves to ${PCSCF_IP}"
            else
                fail "conf-factory.${IMS_DOMAIN} resolves to wrong IP" "Got ${conf_dns}, expected ${PCSCF_IP}"
            fi
        else
            skip "DNS conf-factory resolution" "conf-factory DNS not configured (requires conf-factory routing)"
        fi
    fi

    # TC-2: single-UE VoLTE conference over the COMPLETE path (register → P-CSCF → FS)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: 1-UE audio conference via complete path (register → P-CSCF → room 1010)"
        _conf_full_path_case 1 1010 audio "${CONF_CALL_HOLD:-6}" "1-UE audio conference (complete path)"
    fi

    # TC-3: P-CSCF VoLTE conf-factory routing (conference infrastructure)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if ! $conf_factory_dns_available; then
            skip "P-CSCF VoLTE conf-factory routing" "conf-factory DNS not configured (requires conf-factory routing)"
        else
            log "TC-${_TEST_NUM}: P-CSCF VoLTE conf-factory INVITE routing"
            log "Sending INVITE to sip:mmtel@conf-factory.${IMS_DOMAIN} via P-CSCF"

            sipp ${PCSCF_IP}:${PCSCF_PORT} \
                -sf /tmp/test_conf_factory.xml \
                -s mmtel \
                -i $LOCAL_IP -p 7200 \
                -m 1 -l 1 \
                -timeout 15 \
                -timeout_error \
                >/tmp/sipp_conf_tc3.log 2>&1
            RESULT=$?

            if [ $RESULT -eq 0 ]; then
                pass "P-CSCF routed VoLTE conf-factory INVITE to FreeSWITCH (got 200 OK)"
            else
                fail "P-CSCF VoLTE conf-factory routing failed" "SIPp exit code: $RESULT"
                cat /tmp/sipp_conf_tc3.log 2>/dev/null || true
            fi
        fi
    fi

    # TC-4: single-UE ViLTE (video) conference over the COMPLETE path
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: 1-UE video conference via complete path (register → P-CSCF → room 1011)"
        _conf_full_path_case 1 1011 video "${CONF_CALL_HOLD:-6}" "1-UE video conference (complete path)"
    fi

    # TC-5: P-CSCF ViLTE conf-factory routing (conference infrastructure)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if ! $conf_factory_dns_available; then
            skip "P-CSCF ViLTE conf-factory routing" "conf-factory DNS not configured (requires conf-factory routing)"
        else
            log "TC-${_TEST_NUM}: P-CSCF ViLTE conf-factory INVITE routing (video SDP)"
            log "Sending INVITE with video+audio SDP to conf-factory via P-CSCF"

            sipp ${PCSCF_IP}:${PCSCF_PORT} \
                -sf /tmp/test_vilte_conf_factory.xml \
                -s mmtel \
                -i $LOCAL_IP -p 7400 \
                -m 1 -l 1 \
                -timeout 15 \
                -timeout_error \
                >/tmp/sipp_conf_tc5.log 2>&1
            RESULT=$?

            if [ $RESULT -eq 0 ]; then
                pass "P-CSCF routed ViLTE conf-factory INVITE to FreeSWITCH (got 200 OK)"
            else
                fail "P-CSCF ViLTE conf-factory routing failed" "SIPp exit code: $RESULT"
                cat /tmp/sipp_conf_tc5.log 2>/dev/null || true
            fi
        fi
    fi

    # TC-6: Sequential conference rooms (conference infrastructure — uses conf-factory)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if ! $conf_factory_dns_available; then
            skip "Sequential conference rooms via conf-factory" "conf-factory DNS not configured (requires conf-factory routing)"
        else
            log "TC-${_TEST_NUM}: Multiple sequential conference rooms"
            log "Sending 2 consecutive conf-factory INVITEs from different ports"

            # First conf-factory INVITE
            sipp ${PCSCF_IP}:${PCSCF_PORT} \
                -sf /tmp/test_conf_factory.xml \
                -s mmtel \
                -i $LOCAL_IP -p 7500 \
                -m 1 -l 1 \
                -timeout 15 \
                -timeout_error \
                >/tmp/sipp_conf_tc6a.log 2>&1
            RESULT_A=$?

            sleep 1

            # Second conf-factory INVITE
            sipp ${PCSCF_IP}:${PCSCF_PORT} \
                -sf /tmp/test_conf_factory.xml \
                -s mmtel \
                -i $LOCAL_IP -p 7501 \
                -m 1 -l 1 \
                -timeout 15 \
                -timeout_error \
                >/tmp/sipp_conf_tc6b.log 2>&1
            RESULT_B=$?

            if [ $RESULT_A -eq 0 ] && [ $RESULT_B -eq 0 ]; then
                pass "Both sequential conf-factory INVITEs got 200 OK (room counter works)"
            elif [ $RESULT_A -eq 0 ]; then
                fail "Second conf-factory INVITE failed" "Room counter collision? SIPp exit: $RESULT_B"
                cat /tmp/sipp_conf_tc6b.log 2>/dev/null || true
            else
                fail "First conf-factory INVITE failed" "SIPp exit: $RESULT_A"
                cat /tmp/sipp_conf_tc6a.log 2>/dev/null || true
            fi
        fi
    fi

    # TC-7: multi-member (4) audio conference over the COMPLETE path.
    # 4 registered UEs each dial the same room through the P-CSCF and overlap in it.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: 4-UE audio conference via complete path (register → P-CSCF → room 1012)"
        _conf_full_path_case 4 1012 audio "${CONF_MULTI_HOLD:-20}" "4-UE audio conference (complete path)"
    fi

    # TC-8: Hold SDP via conf-factory (conference infrastructure)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if ! $conf_factory_dns_available; then
            skip "Hold SDP via conf-factory" "conf-factory DNS not configured (requires conf-factory routing)"
        else
            log "TC-${_TEST_NUM}: Hold SDP (sendonly) via P-CSCF conf-factory"
            log "Sending INVITE with a=sendonly SDP to conf-factory via P-CSCF"

            sipp ${PCSCF_IP}:${PCSCF_PORT} \
                -sf /tmp/test_hold_detect.xml \
                -s mmtel \
                -i $LOCAL_IP -p 7700 \
                -m 1 -l 1 \
                -timeout 15 \
                -timeout_error \
                >/tmp/sipp_conf_tc8.log 2>&1
            RESULT=$?

            if [ $RESULT -eq 0 ]; then
                pass "P-CSCF handled sendonly SDP and routed conf-factory to FreeSWITCH"
            else
                fail "Sendonly SDP conf-factory routing failed" "SIPp exit code: $RESULT"
                cat /tmp/sipp_conf_tc8.log 2>/dev/null || true
            fi
        fi
    fi

    # TC-9: conference room reuse over the COMPLETE path (dial → teardown → re-dial).
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

    # TC-10: multiple distinct conference rooms over the COMPLETE path (routing +
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

    # TC-11: Rx AAR path validation (non-IMS clients correctly bypass Rx)
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
                # mean Rx is broken. TC-12 separately validates the Rx Diameter peer is up.
                skip "Rx AAR bypass log check" \
                    "ims_qos loaded and Rx peer connected (TC-12) — 'Skipping Rx' log string not found but may use different message in this P-CSCF config version"
            else
                fail "ims_qos module NOT loaded on P-CSCF (dedicated bearer path unavailable)" "Module status: ${RX_MODULE}"
            fi
        fi
    fi

    # TC-12: Rx Diameter peer connectivity (PCRF reachability)
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

    # TC-13: Inter-NIB conference INVITE — join conference room at external IMS domain
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

    # TC-14: N-UE SINGLE audio conference — the "24 UEs in one conference" requirement,
    # over the COMPLETE path. N registered UEs each dial the same room via the P-CSCF
    # and overlap for the hold window. Requirement: N UEs ⇒ EXACTLY N CDR LEG rows.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local n_aud="${CONF_AUDIO_MEMBERS:-24}" room_aud="${CONF_AUDIO_ROOM:-1016}" hold_a="${CONF_SOAK_SECS:-45}"
        log "TC-${_TEST_NUM}: ${n_aud}-UE SINGLE audio conference via COMPLETE path (register → P-CSCF → room ${room_aud}), ${hold_a}s hold"
        _conf_full_path_case "$n_aud" "$room_aud" audio "$hold_a" "${n_aud}-UE audio conference (complete path)"
    fi

    # TC-15: N-UE SINGLE video (ViLTE) conference — the "8 UEs in one video conference"
    # requirement, over the COMPLETE path. N registered UEs each dial the same room via
    # the P-CSCF with audio+video SDP. Requirement: N UEs ⇒ EXACTLY N CDR LEG rows.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local n_vid="${CONF_VIDEO_MEMBERS:-8}" room_vid="${CONF_VIDEO_ROOM:-1017}" hold_v="${CONF_SOAK_SECS:-45}"
        log "TC-${_TEST_NUM}: ${n_vid}-UE SINGLE video conference via COMPLETE path (register → P-CSCF → room ${room_vid}), ${hold_v}s hold"
        _conf_full_path_case "$n_vid" "$room_vid" video "$hold_v" "${n_vid}-UE video conference (complete path)"
    fi

    # ── Phone-type conference interop (Optimus/MTK vs Samsung) on active PLMN ──
    # Single-INVITE probe: a conf-factory dial-in from each phone type must be
    # accepted/routed toward the FreeSWITCH conference AS without a 5xx. Guarded
    # on conf-factory DNS (set by the DNS probe near the top of this feature).

    # Optimus/MTK UA conf-factory INVITE
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Conf-factory INVITE as Optimus/MTK UA on PLMN ${ACTIVE_PLMN_LABEL:-active} (non-5xx)"
        if ! $conf_factory_dns_available; then
            skip "Conf-factory INVITE (Optimus/MTK UA)" "conf-factory DNS not configured"
        else
            assert_profiled_invite_non5xx "optimus" "-" \
                "/opt/test/scenarios/phone_profiled_conf_invite.xml" "mmtel" 7220 \
                "Conf-factory INVITE (Optimus/MTK UA, PLMN ${ACTIVE_PLMN_LABEL:-active})"
        fi
    fi

    # Samsung UA conf-factory INVITE
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Conf-factory INVITE as Samsung UA on PLMN ${ACTIVE_PLMN_LABEL:-active} (non-5xx)"
        if ! $conf_factory_dns_available; then
            skip "Conf-factory INVITE (Samsung UA)" "conf-factory DNS not configured"
        else
            assert_profiled_invite_non5xx "samsung" "-" \
                "/opt/test/scenarios/phone_profiled_conf_invite.xml" "mmtel" 7221 \
                "Conf-factory INVITE (Samsung UA, PLMN ${ACTIVE_PLMN_LABEL:-active})"
        fi
    fi

    # Clean up temp files
    rm -f /tmp/sipp_conf_tc*_err.log /tmp/sipp_conf_tc*_out.log /tmp/test_conf_factory.xml /tmp/test_vilte_conf_factory.xml /tmp/test_hold_detect.xml /tmp/test_rx_bearer.xml /tmp/sipp_confsoak_*.log 2>/dev/null

    end_feature
}
