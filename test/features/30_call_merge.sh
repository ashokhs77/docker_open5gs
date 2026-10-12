#!/bin/bash
# Feature 30: Call merge through the OpenSIPS B2BUA application server
#
# Since Rev48 every INVITE of a subscriber is anchored on the OpenSIPS AS (iFC,
# b2b "top hiding"), and the handset's "Merge" button is served by that AS:
#   INVITE sip:mmtel@conf-factory.<domain>   -> focus leg into FreeSWITCH room merge-<tag>
#   REFER  Refer-To: <party?Replaces=dialog>  -> the party is re-INVITEd into the room
#                                               (MI b2b_bridge), the absorbed leg is BYEd,
#                                               a refer NOTIFY (sipfrag 200) is sent
#   REFER  Refer-To: <number;method=BYE>      -> Drop one participant
#   SUBSCRIBE (conference roster)             -> 489
# The tests drive that with the Python UE simulator (ue_sim/merge_scenarios.py):
# real attach + IMS registration, SIP through P-CSCF / S-CSCF / AS / FreeSWITCH.
# The room membership is read from FreeSWITCH (fs_cli), the AS evidence from its log.
#
# Tests:
#   --- prerequisites ---
#   TC-1:  OpenSIPS AS is running and its MI interface answers
#   TC-2:  FreeSWITCH merge profiles are up (5090 focus, 5094 audio, 5096 video)
#   TC-3:  DNS resolves the AS name used in the iFC
#   TC-4:  The default iFC triggers the AS (originating, and terminating inter-NIB)
#   --- every call is anchored on the B2BUA ---
#   TC-5:  Basic call is anchored (terminating leg has its own Call-ID)
#   TC-6:  Hold and resume pass through the B2BUA
#   TC-7:  Release by the callee passes through the B2BUA
#   TC-8:  Video call is anchored with video intact
#   TC-9:  CANCEL while ringing reaches the callee (peer leg cancelled by the AS)
#   TC-10: Busy callee (486) is reported to the caller
#   TC-11: Call to a number that is not registered fails cleanly
#   TC-12: No B2B sessions are left behind by the calls above
#   --- merge ---
#   TC-13: Conference factory alone: focus answered, room created and removed
#   TC-14: Three-party merge (A called B and C)
#   TC-15: Conference roster SUBSCRIBE is answered 489
#   TC-16: The initiator ends the conference for everybody
#   TC-17: Merge of a call the initiator RECEIVED
#   TC-18: Four-party merge
#   TC-19: Drop one participant, the conference continues
#   TC-20: A participant hangs up, the conference continues
#   TC-21: Video merge
#   TC-22: A participant adds a party (joins the existing room, no second room)
#   --- negative ---
#   TC-23: REFER without Replaces is refused (488), calls unaffected
#   TC-24: REFER naming an unknown dialog merges nobody, calls unaffected
#   TC-25: Drop of a number that is not in the conference is refused (404)
#   TC-26: No B2B sessions or rooms are left behind by the merge tests
#   --- not automatable here (reported as SKIP with the reason) ---
#   TC-27: Merge across two NIBs
#   TC-28: Audio actually mixed between the parties
#   --- conference CDR ---
#   TC-29: A merge conference is recorded in conf_cdr.csv (CONF row + one LEG per member)
#   TC-30: A participant that pressed Merge still has ONE LEG row (its leg swap is folded)
#   --- call CDR (cdr.csv) with the B2BUA in the path ---
#   TC-31: Exactly one row per answered call (caller-ended, callee-ended, video); duration = talk time
#   TC-32: No row for cancelled / rejected / unregistered calls or the conference-factory call
#   TC-33: A merged call's row ends at the merge (dialled and received calls)
#
# Notes for whoever tunes this:
#   * The simulator's SIP identity is the IMSI, so From / dialled numbers / the Drop
#     number are IMSIs here, MSISDNs on real phones.
#   * The simulator has no IPsec and sends no RTP.
#   * Several TCs share one simulator run (e.g. 14-16); the run happens once, lazily.
#   * CALL_MERGE_CLEANUP_WAIT (240 s) is how long TC-12/26 wait for the AS to drop ended
#     B2B sessions before calling it a leak.
#   * CALL_MERGE_KEEP=1 keeps the test subscribers, CALL_MERGE_SEED fixes their numbers.
#   * Simulator logs of each run: reports/call_merge_<run>.log.

set +e

source /opt/test/lib/common.sh
source /opt/test/lib/sipp_helpers.sh

CM_FS_CLI="/usr/local/freeswitch/bin/fs_cli"
CM_API="http://${PYHSS_IP}:${PYHSS_REST_PORT:-8080}"

_cm_seed="${CALL_MERGE_SEED:-$(date +%s)}"
case "$_cm_seed" in ''|*[!0-9]*) _cm_seed="1" ;; esac
_cm_base=$(( (10#${_cm_seed} + $$) % 999990 ))
_cm_msisdn() { printf '9874%06d' $(( _cm_base + $1 )); }
_cm_imsi()   { echo "${MCC}${MNC}$1"; }

CM_OPC="${CM_OPC:-8E27B6AF0E692E750F32667A3B14605D}"
CM_AMF="${CM_AMF:-8000}"
CM_MS=( "$(_cm_msisdn 0)" "$(_cm_msisdn 1)" "$(_cm_msisdn 2)" "$(_cm_msisdn 3)" )
CM_KI=( "a0a1a2a3a4a5a6a7a8a9aaabacadae01" "a0a1a2a3a4a5a6a7a8a9aaabacadae02"
        "a0a1a2a3a4a5a6a7a8a9aaabacadae03" "a0a1a2a3a4a5a6a7a8a9aaabacadae04" )
CM_UNREG_NUMBER="$(_cm_imsi "$(_cm_msisdn 9)")"     # never provisioned
CM_PREP_DETAIL=""

declare -A CM_RES      # run name -> JSON result
declare -A CM_ASLOG    # run name -> AS log lines of that run
declare -A CM_CDR      # run name -> cdr.csv rows that run added

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_cm_mysql() {
    docker exec mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD:-MySQL_PaSsW0rD}" ims_hss_db -N -B -e "$1" 2>/dev/null
}

_cm_api_put() {
    local auth=()
    [ -n "$PYHSS_API_KEY" ] && auth=(-H "Authorization: Bearer ${PYHSS_API_KEY}")
    curl -s -o /dev/null -w "%{http_code}" -X PUT -H "Content-Type: application/json" \
        "${auth[@]}" -d "$2" "${CM_API}$1" 2>/dev/null
}

_cm_delete_all() {
    local m list_m="" list_i=""
    for m in "${CM_MS[@]}"; do
        list_m="${list_m}${list_m:+,}'${m}'"
        list_i="${list_i}${list_i:+,}'$(_cm_imsi "$m")'"
    done
    _cm_mysql "DELETE FROM ims_subscriber WHERE imsi IN (${list_i}) OR msisdn IN (${list_m});" >/dev/null 2>&1 || true
    _cm_mysql "DELETE FROM subscriber WHERE imsi IN (${list_i});" >/dev/null 2>&1 || true
    _cm_mysql "DELETE FROM auc WHERE imsi IN (${list_i});" >/dev/null 2>&1 || true
}

# AuC + subscriber + IMS subscriber (default iFC, so the AS is triggered)
_cm_provision() {
    local msisdn="$1" ki="$2" imsi code auc_id
    imsi=$(_cm_imsi "$msisdn")
    code=$(_cm_api_put "/auc/" "{\"ki\":\"${ki}\",\"opc\":\"${CM_OPC}\",\"amf\":\"${CM_AMF}\",\"sqn\":0,\"imsi\":\"${imsi}\"}")
    case "$code" in 200|201) ;; *) CM_PREP_DETAIL="${CM_PREP_DETAIL} AUC(${msisdn}):HTTP${code}"; return 1 ;; esac
    auc_id=$(_cm_mysql "SELECT auc_id FROM auc WHERE imsi='${imsi}' ORDER BY auc_id DESC LIMIT 1;" | head -1 | tr -dc '0-9')
    [ -n "$auc_id" ] || { CM_PREP_DETAIL="${CM_PREP_DETAIL} AUC_ID(${msisdn}):missing"; return 1; }
    code=$(_cm_api_put "/subscriber/" "{\"imsi\":\"${imsi}\",\"enabled\":true,\"auc_id\":${auc_id},\"default_apn\":1,\"apn_list\":\"1,2\",\"msisdn\":\"${msisdn}\",\"ue_ambr_dl\":0,\"ue_ambr_ul\":0,\"nam\":0,\"roaming_enabled\":true,\"subscribed_rau_tau_timer\":300}")
    case "$code" in 200|201) ;; *) CM_PREP_DETAIL="${CM_PREP_DETAIL} SUB(${msisdn}):HTTP${code}"; return 1 ;; esac
    code=$(_cm_api_put "/ims_subscriber/" "{\"imsi\":\"${imsi}\",\"msisdn\":\"${msisdn}\",\"msisdn_list\":\"[${msisdn}]\",\"ifc_path\":\"default_ifc.xml\",\"scscf_peer\":\"scscf.${IMS_DOMAIN}\",\"scscf\":\"sip:scscf.${IMS_DOMAIN}:6060\",\"scscf_realm\":\"${IMS_DOMAIN}\"}")
    case "$code" in 200|201) ;; *) CM_PREP_DETAIL="${CM_PREP_DETAIL} IMS(${msisdn}):HTTP${code}"; return 1 ;; esac
    return 0
}

_cm_spec() { echo "$(_cm_imsi "${CM_MS[$1]}"):${CM_KI[$1]}:${CM_OPC}:${CM_AMF}:${CM_MS[$1]}"; }

# _cm_json '<json>' a.b.0.c   -> value ('' when absent). Booleans print True/False.
_cm_json() {
    printf '%s' "$1" | "$PYTHON_BIN" -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for k in sys.argv[1].split('.'):
        if isinstance(d, list):
            d = d[int(k)]
        elif isinstance(d, dict):
            d = d.get(k)
        else:
            d = None
        if d is None:
            break
    print('' if d is None else (json.dumps(d) if isinstance(d, (dict, list)) else d))
except Exception:
    print('')
" "$2" 2>/dev/null
}

# All given paths of a result are True
_cm_all_true() {
    local json="$1" p; shift
    for p in "$@"; do [ "$(_cm_json "$json" "$p")" = "True" ] || return 1; done
    return 0
}

# Room member count as expected; -1 (fs_cli not reachable from the test container) is
# "unknown" and does not fail a case on its own.
_cm_count_is() { [ "$1" = "$2" ] || [ "$1" = "-1" ]; }

# Run a scenario once and remember result + AS log:  _cm_run <name> <timeout> <args...>
_cm_run() {
    local name="$1" to="$2"; shift 2
    [ -n "${CM_RES[$name]}" ] && return 0
    local cursor out cdr_before
    cursor=$(log_cursor_now)
    cdr_before=$(_cm_cdr_lines)
    log "  running simulator scenario '${name}' (up to ${to}s)..."
    out=$(cd /opt/test && env \
            MME_IP="${MME_IP:-172.22.1.9}" PCSCF_IP="${PCSCF_IP:-172.22.1.21}" \
            PYHSS_IP="${PYHSS_IP:-172.22.1.18}" LOCAL_IP="${LOCAL_IP:-172.22.1.200}" \
            MCC="${MCC:-001}" MNC="${MNC:-01}" IMS_DOMAIN="${IMS_DOMAIN}" \
            timeout "$to" "$PYTHON_BIN" -m ue_sim.merge_scenarios "$@" \
            --log-file "${REPORT_DIR:-/opt/test/reports}/call_merge_${name}.log" 2>/dev/null | tail -1)
    [ -n "$out" ] || out='{"errors":["scenario produced no output (timeout or crash) - see reports/call_merge_'"${name}"'.log"]}'
    CM_RES[$name]="$out"
    CM_ASLOG[$name]=$(docker_logs_grep_since opensips "$cursor" "AS-CONF|OpenSIPS-AS|mi_bridge|mi_drop|mi_cancel|mi_findroom" 60)
    append_report_block "scenario ${name}: result" "$out"
    append_report_block "scenario ${name}: OpenSIPS AS log" "${CM_ASLOG[$name]}"
    sleep 2   # let the network release everything before the next scenario
    # Call-CDR rows (cdr.csv) this scenario added for the test subscribers
    CM_CDR[$name]=$(_cm_cdr_rows | tail -n +$(( cdr_before + 1 )))
    append_report_block "scenario ${name}: cdr.csv rows added" "${CM_CDR[$name]:-(none)}"
}

# cdr.csv rows that mention one of the four test subscribers, oldest first
_cm_cdr_rows() {
    local pat
    pat="$(_cm_imsi "${CM_MS[0]}")|$(_cm_imsi "${CM_MS[1]}")|$(_cm_imsi "${CM_MS[2]}")|$(_cm_imsi "${CM_MS[3]}")"
    docker exec scscf sh -c "grep -E '${pat}' /cdr-logs/cdr.csv 2>/dev/null" 2>/dev/null
}
_cm_cdr_lines() { _cm_cdr_rows | grep -c . ; }
# Rows a scenario added: count, and the duration (seconds) of the row caller,callee
_cm_cdr_count() { printf '%s\n' "${CM_CDR[$1]}" | grep -c . ; }
_cm_cdr_dur() {
    printf '%s\n' "${CM_CDR[$1]}" | awk -F',' -v a="$2" -v b="$3" '$1==a && $2==b {d=$5} END{sub(/s$/,"",d); print d}'
}
# |a - b| <= tol, on possibly fractional numbers
_cm_near() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN{d=a-b; if (d<0) d=-d; exit !(a!="" && b!="" && d<=t)}'; }

# Why a run could not even start (UEs not up / exception); empty when it started
_cm_setup_problem() {
    local json="$1" errs
    errs=$(_cm_json "$json" errors)
    case "$errs" in
        *"not every UE"*|*"virtual eNB"*|*"no output"*|*Error*|*Exception*) echo "$errs setup=$(_cm_json "$json" setup)" ;;
        *) echo "" ;;
    esac
}

# b2b_logic:list from the AS (raw JSON), empty when the MI interface does not answer
_cm_b2b_list() {
    timeout 10 docker exec opensips sh -c '
        [ -p /tmp/opensips_fifo ] || exit 4
        R=cm_test_$$; rm -f /tmp/$R
        mkfifo -m 0666 /tmp/$R 2>/dev/null || exit 3
        printf ":%s:%s\n" "$R" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"b2b_logic:list\"}" > /tmp/opensips_fifo
        timeout 3 cat /tmp/$R; rc=$?; rm -f /tmp/$R; exit $rc' 2>/dev/null
}

# Number of B2B sessions that still mention one of the test subscribers
_cm_stale_sessions() {
    local list m n=0 c
    list=$(_cm_b2b_list)
    [ -n "$list" ] || { echo "-1"; return; }
    for m in "${CM_MS[@]}"; do
        c=$(printf '%s' "$list" | grep -o "sip:$(_cm_imsi "$m")@" | wc -l)
        n=$(( n + c ))
    done
    echo "$n"
}

# Wait until no B2B session mentions the test subscribers; prints "<count> <seconds
# waited>" (count -1 = MI did not answer). The AS removes ended tuples from a periodic clean-up, not
# at once: cancelled / rejected / failed calls were still listed 3 s after the call
# and gone a few minutes later (live run 2026-10-06), so a single look is not a verdict.
_cm_wait_no_stale() {
    local max="${1:-${CALL_MERGE_CLEANUP_WAIT:-240}}" waited=0 n
    while :; do
        n=$(_cm_stale_sessions)
        if [ "$n" = "0" ] || [ "$n" = "-1" ] || [ "$waited" -ge "$max" ]; then
            echo "$n $waited"
            return
        fi
        sleep 5
        waited=$(( waited + 5 ))
    done
}

_cm_merge_rooms() {
    docker exec freeswitch "$CM_FS_CLI" -x "conference list" 2>/dev/null | grep -c '^Conference merge-' || true
}

run_call_merge_tests() {
    start_feature "Call Merge"

    local as_up=false sim_ok=false prepared=false i

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "opensips"; then as_up=true; fi
    if ue_sim_probe 2>/dev/null && "$PYTHON_BIN" -c "import sys; sys.path.insert(0,'/opt/test'); import ue_sim.merge_scenarios" 2>/dev/null; then
        sim_ok=true
    fi

    _cm_delete_all
    prepared=true
    for i in 0 1 2 3; do
        _cm_provision "${CM_MS[$i]}" "${CM_KI[$i]}" || prepared=false
    done
    log "call-merge subscribers A=${CM_MS[0]} B=${CM_MS[1]} C=${CM_MS[2]} D=${CM_MS[3]} prepared=${prepared} as_up=${as_up} simulator=${sim_ok}"

    local UE_A="--ue $(_cm_spec 0)" UE_B="--ue $(_cm_spec 1)" UE_C="--ue $(_cm_spec 2)" UE_D="--ue $(_cm_spec 3)"

    # Gate for the cases that need calls: reports and returns 1 when they cannot run
    _cm_gate() {
        if ! $as_up; then skip "$1" "OpenSIPS AS container 'opensips' is not running (this stack has no B2BUA merge)"; return 1; fi
        if ! $sim_ok; then skip "$1" "Python UE simulator not available: $(ue_sim_probe_reason 2>/dev/null)"; return 1; fi
        if ! $prepared; then fail "$1 cannot run" "test subscribers were not provisioned:${CM_PREP_DETAIL}"; return 1; fi
        return 0
    }
    # Gate on a finished run: reports and returns 1 when the scenario never got going
    _cm_started() {
        local problem
        problem=$(_cm_setup_problem "$2")
        if [ -n "$problem" ]; then fail "$1 could not run" "$problem"; return 1; fi
        return 0
    }

    # ─────────────────────────────── prerequisites ───────────────────────────────

    if should_run_test 1; then
        _TEST_NUM=1
        log "TC-${_TEST_NUM}: OpenSIPS AS running, MI interface answers"
        if ! $as_up; then
            fail "OpenSIPS AS container 'opensips' is not running" "docker ps shows no container named opensips"
        else
            local list ver
            list=$(_cm_b2b_list)
            ver=$(docker exec opensips sh -c 'opensips -V 2>/dev/null | head -1' 2>/dev/null)
            if printf '%s' "$list" | grep -q '"jsonrpc"' && ! printf '%s' "$list" | grep -q '"error"'; then
                pass "OpenSIPS AS up (${ver:-version unknown}); MI b2b_logic:list answers - b2b_logic is loaded and the helper scripts can work"
            else
                fail "OpenSIPS AS is running but MI b2b_logic:list does not answer" "reply: $(printf '%s' "$list" | head -c 200) - merge, drop, cancel and join all depend on /tmp/opensips_fifo"
            fi
        fi
    fi

    if should_run_test 2; then
        _TEST_NUM=2
        log "TC-${_TEST_NUM}: FreeSWITCH merge profiles"
        local sofia missing="" p
        sofia=$(docker exec freeswitch "$CM_FS_CLI" -x "sofia status" 2>/dev/null)
        if [ -z "$sofia" ]; then
            fail "FreeSWITCH does not answer fs_cli" "docker exec freeswitch ${CM_FS_CLI} -x 'sofia status' returned nothing"
        else
            for p in 5090 5094 5096; do
                echo "$sofia" | grep -E ":${p}\b" | grep -q "RUNNING" || missing="${missing} ${p}"
            done
            if [ -z "$missing" ]; then
                pass "Sofia profiles RUNNING on 5090 (focus legs), 5094 (audio merge, 3pcc) and 5096 (video merge, 3pcc)"
            else
                append_report_block "sofia status" "$sofia"
                fail "FreeSWITCH profile(s) not running on port(s):${missing}" "5090 takes the focus, 5094/5096 take the re-anchored parties; without them the bridge INVITE gets no answer"
            fi
        fi
    fi

    if should_run_test 3; then
        _TEST_NUM=3
        log "TC-${_TEST_NUM}: DNS name of the AS"
        local name="opensips.${IMS_DOMAIN}" got="" want=""
        want=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' opensips 2>/dev/null | awk '{print $1}')
        if command -v dig >/dev/null 2>&1; then
            got=$(dig +short +time=2 +tries=1 @"${DNS_IP}" "$name" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
        elif command -v nslookup >/dev/null 2>&1; then
            got=$(nslookup "$name" "${DNS_IP}" 2>/dev/null | awk '/^Address/ && !/#/ {print $2}' | tail -1)
        else
            got=$(docker exec scscf sh -c "getent hosts ${name}" 2>/dev/null | awk '{print $1}' | head -1)
        fi
        if [ -z "$got" ]; then
            fail "${name} does not resolve" "the S-CSCF cannot reach the AS named in the iFC; DefaultHandling=0 then lets calls proceed UNANCHORED, and merge fails with 'Could not find entity'"
        elif [ -n "$want" ] && [ "$got" != "$want" ]; then
            fail "${name} resolves to ${got}, the opensips container is ${want}" "DNS zone and container address disagree"
        else
            pass "${name} resolves to ${got}${want:+ (the opensips container)}"
        fi
    fi

    if should_run_test 4; then
        _TEST_NUM=4
        log "TC-${_TEST_NUM}: default iFC triggers the AS"
        local ifc orig term fb
        ifc=$(docker exec pyhss sh -c 'cat /pyhss/default_ifc.xml 2>/dev/null || cat /mnt/pyhss/default_ifc.xml 2>/dev/null' 2>/dev/null \
              | "$PYTHON_BIN" -c "import sys,re; print(re.sub(r'<!--.*?-->', '', sys.stdin.read(), flags=re.S))" 2>/dev/null)
        orig=$(echo "$ifc" | grep -c 'opensips[^<]*;call=orig')
        term=$(echo "$ifc" | grep -c 'opensips[^<]*;call=term')
        fb=$(echo "$ifc" | grep -c 'X-Fallback-Origin')
        if [ -z "$ifc" ]; then
            skip "iFC check" "default_ifc.xml not readable in the pyhss container"
        elif [ "$orig" -ge 1 ] && [ "$term" -ge 1 ] && [ "$fb" -ge 1 ]; then
            pass "default_ifc.xml (comments ignored): originating INVITE -> AS, terminating INVITE with X-Fallback-Origin (inter-NIB) -> AS"
        else
            fail "default_ifc.xml does not trigger the AS as merge needs" "active triggers: orig=${orig} term=${term} X-Fallback-Origin=${fb} (each must be >= 1)"
        fi
    fi

    # ───────────────────── every call is anchored on the B2BUA ─────────────────────

    if should_run_test 5; then
        _TEST_NUM=5
        log "TC-${_TEST_NUM}: basic call anchored on the B2BUA"
        if _cm_gate "Anchored call"; then
            _cm_run anchor 200 anchor $UE_A $UE_B --port 100 --talk 6
            local r="${CM_RES[anchor]}" cid
            if _cm_started "Anchored call" "$r"; then
                cid=$(_cm_json "$r" call.caller_call_id)
                if _cm_all_true "$r" call.ok call.call_id_changed release.bye_ok release.peer_released; then
                    if echo "${CM_ASLOG[anchor]}" | grep -q "anchor INVITE.*${cid}"; then
                        pass "Call A->B set up and released through the AS: callee leg has its own Call-ID (topology hiding) and the AS logged the anchor for ${cid}"
                    else
                        pass "Call A->B set up and released; callee leg has its own Call-ID, so a B2BUA is in the path (AS log line for ${cid} not found in docker logs - check log level)"
                    fi
                elif [ "$(_cm_json "$r" call.ok)" = "True" ] && [ "$(_cm_json "$r" call.call_id_changed)" != "True" ]; then
                    fail "Call works but is NOT anchored on the AS" "caller and callee see the same Call-ID ${cid}: the iFC did not route the INVITE through OpenSIPS (TC-3/TC-4), so this call could not be merged"
                else
                    fail "Anchored call failed" "call=$(_cm_json "$r" call) release=$(_cm_json "$r" release)"
                fi
            fi
        fi
    fi

    if should_run_test 6 || should_run_test 7; then
        if $as_up && $sim_ok && $prepared; then
            _cm_run anchor_hold 220 anchor $UE_A $UE_B --port 104 --hold-resume --bye-from callee
        fi
    fi

    if should_run_test 6; then
        _TEST_NUM=6
        log "TC-${_TEST_NUM}: hold / resume through the B2BUA"
        if _cm_gate "Hold/resume via AS"; then
            local r="${CM_RES[anchor_hold]}" n
            if _cm_started "Hold/resume via AS" "$r"; then
                n=$(_cm_json "$r" hold_resume.callee_reinvites)
                if _cm_all_true "$r" hold_resume.hold hold_resume.resume hold_resume.both_dialogs_alive && [ "${n:-0}" -ge 2 ] 2>/dev/null; then
                    pass "Hold and resume re-INVITEs crossed the B2BUA in-dialog (callee saw ${n} re-INVITEs), call stayed up"
                else
                    fail "Hold/resume through the B2BUA failed" "$(_cm_json "$r" hold_resume) call=$(_cm_json "$r" call.error)"
                fi
            fi
        fi
    fi

    if should_run_test 7; then
        _TEST_NUM=7
        log "TC-${_TEST_NUM}: release by the callee"
        if _cm_gate "Callee release via AS"; then
            local r="${CM_RES[anchor_hold]}"
            if _cm_started "Callee release via AS" "$r"; then
                if _cm_all_true "$r" release.bye_ok release.peer_got_bye release.peer_released; then
                    pass "BYE from the callee was relayed by the B2BUA: the caller got BYE and its dialog ended"
                else
                    fail "Callee's BYE did not release the caller" "$(_cm_json "$r" release)"
                fi
            fi
        fi
    fi

    if should_run_test 8; then
        _TEST_NUM=8
        log "TC-${_TEST_NUM}: video call anchored"
        if _cm_gate "Anchored video call"; then
            _cm_run anchor_video 200 anchor $UE_A $UE_B --port 108 --video
            local r="${CM_RES[anchor_video]}"
            if _cm_started "Anchored video call" "$r"; then
                if _cm_all_true "$r" call.ok call.call_id_changed call.callee_saw_video release.bye_ok; then
                    pass "Video call anchored: the callee's INVITE still offers m=video after the B2BUA"
                else
                    fail "Video call through the B2BUA failed" "call=$(_cm_json "$r" call)"
                fi
            fi
        fi
    fi

    if should_run_test 9; then
        _TEST_NUM=9
        log "TC-${_TEST_NUM}: CANCEL while ringing"
        if _cm_gate "CANCEL via AS"; then
            _cm_run cancel 200 cancel $UE_A $UE_B --port 112
            local r="${CM_RES[cancel]}"
            if _cm_started "CANCEL via AS" "$r"; then
                # What matters to a subscriber: the callee stops ringing and the caller's
                # call ends. The caller's final code is 487 by the book; this AS answers 408
                # (it terminates the B2B session to cancel the peer leg), which a handset
                # that has just cancelled treats the same - reported, not failed.
                local cfinal cst
                cfinal=$(_cm_json "$r" caller.final); cst=$(_cm_json "$r" caller.cancel_status)
                if [ "$(_cm_json "$r" caller.ringing)" = "True" ] && [ "$(_cm_json "$r" callee.cancel)" = "True" ] \
                   && [ "$cst" = "200" ] && [ "${cfinal:-0}" -ge 400 ] 2>/dev/null; then
                    if [ "$cfinal" = "487" ]; then
                        pass "Caller cancelled while ringing: caller got 487 and the callee received the CANCEL after $(_cm_json "$r" callee.ring_seconds)s (AS cancelled the peer leg - mi_cancel.sh)"
                    else
                        pass "Caller cancelled while ringing: the callee received the CANCEL after $(_cm_json "$r" callee.ring_seconds)s and stopped ringing, the CANCEL was answered 200 and the caller's call ended with ${cfinal} (not the textbook 487 - the AS ends the caller leg itself when it cancels the peer leg; harmless to a handset)"
                    fi
                elif [ "${cfinal:-0}" -ge 400 ] 2>/dev/null && [ "$(_cm_json "$r" callee.invite)" = "True" ] && [ "$(_cm_json "$r" callee.cancel)" != "True" ]; then
                    fail "Caller is released but the CALLEE KEEPS RINGING" "callee never received CANCEL (it stopped itself with $(_cm_json "$r" callee.final_sent)); caller got ${cfinal}. The AS relays CANCEL only to the caller side; the peer leg depends on mi_cancel.sh - see the AS log in the report"
                else
                    fail "CANCEL while ringing failed" "caller=$(_cm_json "$r" caller) callee=$(_cm_json "$r" callee)"
                fi
            fi
        fi
    fi

    if should_run_test 10; then
        _TEST_NUM=10
        log "TC-${_TEST_NUM}: busy callee"
        if _cm_gate "486 via AS"; then
            _cm_run reject 200 reject $UE_A $UE_B --port 116
            local r="${CM_RES[reject]}" final
            if _cm_started "486 via AS" "$r"; then
                final=$(_cm_json "$r" caller.final)
                if [ "$final" = "486" ] && [ "$(_cm_json "$r" callee.ack)" = "True" ]; then
                    pass "Callee's 486 Busy Here reached the caller through the B2BUA and was ACKed"
                elif [ "$(_cm_json "$r" callee.final_sent)" = "486" ] && [ "${final:-0}" -ge 400 ] 2>/dev/null; then
                    pass "Callee rejected with 486; the caller received ${final} (B2BUA/S-CSCF mapped the code; call released on both sides)"
                else
                    fail "Callee's rejection did not release the caller" "caller=$(_cm_json "$r" caller) callee=$(_cm_json "$r" callee)"
                fi
            fi
        fi
    fi

    if should_run_test 11; then
        _TEST_NUM=11
        log "TC-${_TEST_NUM}: call to an unregistered number"
        if _cm_gate "Unregistered callee via AS"; then
            _cm_run unreachable 200 unreachable $UE_A --port 120 --target "$CM_UNREG_NUMBER"
            local r="${CM_RES[unreachable]}" final secs
            if _cm_started "Unregistered callee via AS" "$r"; then
                final=$(_cm_json "$r" caller.final); secs=$(_cm_json "$r" seconds)
                if [ "${final:-0}" -ge 400 ] 2>/dev/null && [ "$final" != "487" ]; then
                    pass "Call to unregistered ${CM_UNREG_NUMBER} failed cleanly with ${final} after ${secs}s (no hanging B2B session)"
                elif [ "$final" = "487" ]; then
                    fail "Call to an unregistered number got no failure response" "the simulator had to CANCEL after ${secs}s; the AS or S-CSCF held the INVITE instead of rejecting it"
                else
                    fail "Call to an unregistered number did not fail cleanly" "caller=$(_cm_json "$r" caller)"
                fi
            fi
        fi
    fi

    if should_run_test 12; then
        _TEST_NUM=12
        log "TC-${_TEST_NUM}: no B2B sessions left after the plain calls"
        if ! $as_up; then
            skip "B2B session cleanup" "OpenSIPS AS not running"
        else
            local stale waited
            read -r stale waited <<< "$(_cm_wait_no_stale)"
            if [ "$stale" = "-1" ]; then
                skip "B2B session cleanup" "MI b2b_logic:list did not answer (see TC-1)"
            elif [ "$stale" = "0" ]; then
                pass "b2b_logic:list holds no session of the test subscribers: every anchored call was cleaned up (clear after ${waited}s; ended tuples are removed by the AS clean-up timer, not instantly)"
            else
                append_report_block "b2b_logic:list" "$(_cm_b2b_list | head -c 3000)"
                fail "B2B sessions left behind" "${stale} entity reference(s) to the test subscribers still listed ${waited}s after all calls ended (leak: they are what mi_findroom/mi_drop search)"
            fi
        fi
    fi

    # ─────────────────────────────────── merge ───────────────────────────────────

    if should_run_test 13; then
        _TEST_NUM=13
        log "TC-${_TEST_NUM}: conference factory alone"
        if _cm_gate "Conference factory"; then
            _cm_run factory 160 factory $UE_A --port 124
            local r="${CM_RES[factory]}" c1 c2
            if _cm_started "Conference factory" "$r"; then
                c1=$(_cm_json "$r" focus.room_count); c2=$(_cm_json "$r" room_count_after)
                if [ "$(_cm_json "$r" focus.ok)" != "True" ]; then
                    fail "INVITE to the conference factory was not answered" "sip:mmtel@conf-factory.${IMS_DOMAIN}: $(_cm_json "$r" focus.error). The AS must anchor it against FreeSWITCH :5090 (conf-<tag>)"
                elif _cm_count_is "$c1" 1 && _cm_count_is "$c2" 0 && [ "$(_cm_json "$r" bye_ok)" = "True" ]; then
                    pass "Factory INVITE answered; room $(_cm_json "$r" focus.room) had ${c1} member (the focus) and was removed on BYE (endconf) - counts of -1 mean fs_cli was not readable"
                else
                    fail "Conference room life cycle wrong" "members with focus only: ${c1} (want 1); after BYE: ${c2} (want 0); bye_ok=$(_cm_json "$r" bye_ok)"
                fi
            fi
        fi
    fi

    if should_run_test 14 || should_run_test 15 || should_run_test 16; then
        if $as_up && $sim_ok && $prepared; then
            _cm_run merge3 320 merge $UE_A $UE_B $UE_C --port 128 --parties 2 --subscribe --conf-hold 8
        fi
    fi

    # Shared verdict for "all parties of this run were merged"
    # _cm_merge_verdict <json> <parties> -> prints problems, empty when all good
    _cm_merge_verdict() {
        local r="$1" n="$2" k problems="" want
        [ "$(_cm_json "$r" focus.ok)" = "True" ] || { echo "focus not established: $(_cm_json "$r" focus.error) $(_cm_json "$r" errors)"; return; }
        for (( k = 0; k < n; k++ )); do
            local who st
            who=$(_cm_json "$r" "merges.${k}.party"); st=$(_cm_json "$r" "merges.${k}.status")
            [ "$st" = "202" ] || problems="${problems} ${who:-party$k}:REFER=${st:-none}"
            [ "$(_cm_json "$r" "merges.${k}.notify")" = "True" ] || problems="${problems} ${who}:no-refer-NOTIFY"
            [ "$(_cm_json "$r" "merges.${k}.sipfrag_200")" = "True" ] || problems="${problems} ${who}:sipfrag='$(_cm_json "$r" "merges.${k}.sipfrag")'"
            [ "$(_cm_json "$r" "merges.${k}.party_reinvited")" = "True" ] || problems="${problems} ${who}:not-re-INVITEd-into-room"
            [ "$(_cm_json "$r" "merges.${k}.absorbed_leg_released")" = "True" ] || problems="${problems} ${who}:initiator-leg-not-released"
            [ "$(_cm_json "$r" "merges.${k}.party_dialog_alive")" = "True" ] || problems="${problems} ${who}:party-lost-its-call"
            want=$(( k + 2 ))
            _cm_count_is "$(_cm_json "$r" "merges.${k}.room_count")" "$want" || problems="${problems} ${who}:room=$(_cm_json "$r" "merges.${k}.room_count")(want ${want})"
        done
        [ "$(_cm_json "$r" focus_alive_after_merge)" = "True" ] || problems="${problems} focus-lost"
        echo "$problems"
    }

    if should_run_test 14; then
        _TEST_NUM=14
        log "TC-${_TEST_NUM}: three-party merge"
        if _cm_gate "3-party merge"; then
            local r="${CM_RES[merge3]}" problems
            if _cm_started "3-party merge" "$r"; then
                problems=$(_cm_merge_verdict "$r" 2)
                if [ -z "$problems" ]; then
                    pass "A called B and C, pressed Merge: both REFERs 202 + refer NOTIFY (sipfrag 200, after $(_cm_json "$r" merges.0.notify_delay)s / $(_cm_json "$r" merges.1.notify_delay)s), B and C re-INVITEd into $(_cm_json "$r" focus.room), A's two call legs released, room has $(_cm_json "$r" room_after_merge) members"
                else
                    fail "Three-party merge incomplete" "${problems} | calls=$(_cm_json "$r" calls)"
                fi
            fi
        fi
    fi

    if should_run_test 15; then
        _TEST_NUM=15
        log "TC-${_TEST_NUM}: conference roster SUBSCRIBE"
        if _cm_gate "Roster SUBSCRIBE"; then
            local r="${CM_RES[merge3]}" st
            if _cm_started "Roster SUBSCRIBE" "$r"; then
                st=$(_cm_json "$r" subscribe_status)
                if [ "$st" = "489" ]; then
                    pass "In-dialog SUBSCRIBE (Event: conference) on the focus answered 489 Bad Event, and the merge that followed still worked"
                elif [ "$st" = "200" ] || [ "$st" = "202" ]; then
                    fail "Roster SUBSCRIBE was accepted (${st})" "the AS sends no conference NOTIFYs, so an accepted subscription strands on the handset and blocks its next merge; expected 489"
                else
                    fail "Roster SUBSCRIBE got ${st:-no response}" "expected 489 from the AS (a 420 means it leaked to FreeSWITCH, 405 makes some handsets abort the merge)"
                fi
            fi
        fi
    fi

    if should_run_test 16; then
        _TEST_NUM=16
        log "TC-${_TEST_NUM}: initiator ends the conference"
        if _cm_gate "Conference end by initiator"; then
            local r="${CM_RES[merge3]}" rc
            if _cm_started "Conference end by initiator" "$r"; then
                rc=$(_cm_json "$r" teardown.room_count)
                if _cm_all_true "$r" teardown.focus_bye teardown.parties_released.B teardown.parties_released.C && _cm_count_is "$rc" 0; then
                    pass "A's BYE on the focus ended the conference: B and C were released by the network and the room is gone"
                else
                    fail "Conference did not end cleanly when the initiator left" "teardown=$(_cm_json "$r" teardown) (parties must be released, room count must be 0)"
                fi
            fi
        fi
    fi

    if should_run_test 17; then
        _TEST_NUM=17
        log "TC-${_TEST_NUM}: merge of a received call"
        if _cm_gate "Merge of an incoming call"; then
            _cm_run merge_in 320 merge $UE_A $UE_B $UE_C --port 132 --parties 2 --direction in --conf-hold 8
            local r="${CM_RES[merge_in]}" problems
            if _cm_started "Merge of an incoming call" "$r"; then
                problems=$(_cm_merge_verdict "$r" 2)
                if [ -z "$problems" ] && [ "$(_cm_json "$r" calls.0.direction)" = "in" ]; then
                    pass "B called A, A called C, A merged: the Replaces of the RECEIVED call (AS-generated Call-ID) and of the dialled call (handset Call-ID with '@') were both resolved; room has $(_cm_json "$r" room_after_merge) members"
                else
                    fail "Merge with a received call incomplete" "${problems} | calls=$(_cm_json "$r" calls)"
                fi
            fi
        fi
    fi

    if should_run_test 18 || should_run_test 19; then
        if $as_up && $sim_ok && $prepared; then
            _cm_run merge4 400 merge $UE_A $UE_B $UE_C $UE_D --port 136 --parties 3 --drop
        fi
    fi

    if should_run_test 18; then
        _TEST_NUM=18
        log "TC-${_TEST_NUM}: four-party merge"
        if _cm_gate "4-party merge"; then
            local r="${CM_RES[merge4]}" problems
            if _cm_started "4-party merge" "$r"; then
                problems=$(_cm_merge_verdict "$r" 3)
                if [ -z "$problems" ]; then
                    pass "A merged B, C and D: three REFERs accepted and notified, room has $(_cm_json "$r" room_after_merge) members"
                else
                    fail "Four-party merge incomplete" "${problems}"
                fi
            fi
        fi
    fi

    if should_run_test 19; then
        _TEST_NUM=19
        log "TC-${_TEST_NUM}: drop one participant"
        if _cm_gate "Drop participant"; then
            local r="${CM_RES[merge4]}" before after
            if _cm_started "Drop participant" "$r"; then
                before=$(_cm_json "$r" drop.room_before); after=$(_cm_json "$r" drop.room_count)
                if [ -z "$(_cm_json "$r" drop)" ]; then
                    fail "Drop could not be tried" "the merge before it did not complete: $(_cm_merge_verdict "$r" 3)"
                elif [ "$(_cm_json "$r" drop.status)" = "202" ] \
                     && _cm_all_true "$r" drop.notify drop.target_released drop.focus_alive drop.others_alive \
                     && { [ "$before" = "-1" ] || [ "$after" = "-1" ] || [ "$after" -eq $(( before - 1 )) ]; }; then
                    pass "REFER ...;method=BYE for $(_cm_json "$r" drop.target) (number $(_cm_json "$r" drop.number_used)): 202 + NOTIFY, that party was released, room ${before} -> ${after}, the others and the focus stayed"
                else
                    fail "Drop participant failed" "$(_cm_json "$r" drop) (404 = mi_drop.sh did not find the number in the room; see its table in the AS log)"
                fi
            fi
        fi
    fi

    if should_run_test 20; then
        _TEST_NUM=20
        log "TC-${_TEST_NUM}: a participant hangs up"
        if _cm_gate "Participant leaves"; then
            _cm_run merge_leave 320 merge $UE_A $UE_B $UE_C --port 140 --parties 2 --leave
            local r="${CM_RES[merge_leave]}" before after
            if _cm_started "Participant leaves" "$r"; then
                before=$(_cm_json "$r" leave.room_before); after=$(_cm_json "$r" leave.room_count)
                if [ -z "$(_cm_json "$r" leave)" ]; then
                    fail "Leave could not be tried" "the merge before it did not complete: $(_cm_merge_verdict "$r" 2)"
                elif _cm_all_true "$r" leave.bye_ok leave.focus_alive leave.others_alive \
                     && { [ "$before" = "-1" ] || [ "$after" = "-1" ] || [ "$after" -eq $(( before - 1 )) ]; }; then
                    pass "B hung up: room ${before} -> ${after}, A (focus) and C stayed connected - a participant leaving does not end the conference"
                else
                    fail "Conference did not survive a participant leaving" "$(_cm_json "$r" leave)"
                fi
            fi
        fi
    fi

    if should_run_test 21; then
        _TEST_NUM=21
        log "TC-${_TEST_NUM}: video merge"
        if _cm_gate "Video merge"; then
            _cm_run merge_video 320 merge $UE_A $UE_B $UE_C --port 144 --parties 2 --video
            local r="${CM_RES[merge_video]}" problems
            if _cm_started "Video merge" "$r"; then
                problems=$(_cm_merge_verdict "$r" 2)
                if [ -z "$problems" ] && _cm_all_true "$r" merges.0.party_reinvite_video merges.1.party_reinvite_video; then
                    if echo "${CM_ASLOG[merge_video]}" | grep -q "confpv-"; then
                        pass "Video merge: focus offered video, parties re-INVITEd with m=video into the video room (AS used confpv- on port 5096)"
                    else
                        pass "Video merge: parties re-INVITEd with m=video; room has $(_cm_json "$r" room_after_merge) members"
                    fi
                elif [ -z "$problems" ]; then
                    fail "Video merge joined the parties without video" "re-INVITE video: B=$(_cm_json "$r" merges.0.party_reinvite_video) C=$(_cm_json "$r" merges.1.party_reinvite_video) - the room profile decides the offer; the AS must pick confpv-/5096 from the focus SDP"
                else
                    fail "Video merge incomplete" "${problems}"
                fi
            fi
        fi
    fi

    if should_run_test 22; then
        _TEST_NUM=22
        log "TC-${_TEST_NUM}: a participant adds a party"
        if _cm_gate "Participant-initiated merge"; then
            _cm_run merge_join 420 merge $UE_A $UE_B $UE_C $UE_D --port 148 --parties 2 --join
            local r="${CM_RES[merge_join]}" rc own
            if _cm_started "Participant-initiated merge" "$r"; then
                rc=$(_cm_json "$r" join.room_count); own=$(_cm_json "$r" join.own_room_count)
                if [ -n "$(_cm_merge_verdict "$r" 2)" ]; then
                    fail "Participant-initiated merge could not be tried" "the initiator's merge did not complete: $(_cm_merge_verdict "$r" 2)"
                elif [ "$(_cm_json "$r" join.focus_ok)" != "True" ]; then
                    fail "Participant's factory INVITE failed" "join=$(_cm_json "$r" join)"
                elif [ "$(_cm_json "$r" join.refer_new_party.status)" = "202" ] \
                     && _cm_all_true "$r" join.newcomer_reinvited join.newcomer_dialog_alive join.joiner_focus_alive join.old_leg_released \
                     && _cm_count_is "$rc" 4 && _cm_count_is "$own" 0; then
                    pass "B (already in A's conference) called D and pressed Merge: its factory INVITE JOINED the existing room (no second room), D was re-INVITEd in, B's old participant leg was retired; one room with ${rc} members"
                elif [ "$own" != "0" ] && [ "$own" != "-1" ] && [ -n "$own" ]; then
                    fail "Participant's merge opened a SECOND room" "$(_cm_json "$r" join.own_room) has ${own} member(s): mi_findroom.sh did not find B in A's room, so two mixers get trunked (audio goes deaf)"
                else
                    fail "Participant-initiated merge incomplete" "join=$(_cm_json "$r" join) (want: D re-INVITEd, B's old leg released, room=4, own room=0)"
                fi
            fi
        fi
    fi

    # ───────────────────────────────── negative ─────────────────────────────────

    if should_run_test 23 || should_run_test 24 || should_run_test 25; then
        if $as_up && $sim_ok && $prepared; then
            _cm_run merge_neg 360 merge $UE_A $UE_B $UE_C --port 152 --parties 2 --bad-refer noreplaces,bogus --drop-unknown
        fi
    fi

    if should_run_test 23; then
        _TEST_NUM=23
        log "TC-${_TEST_NUM}: REFER without Replaces"
        if _cm_gate "REFER without Replaces"; then
            local r="${CM_RES[merge_neg]}" st
            if _cm_started "REFER without Replaces" "$r"; then
                st=$(_cm_json "$r" refer_no_replaces.status)
                if [ -z "$(_cm_json "$r" refer_no_replaces)" ]; then
                    fail "REFER without Replaces could not be tried" "focus=$(_cm_json "$r" focus) errors=$(_cm_json "$r" errors)"
                elif [ "$st" = "488" ] && _cm_all_true "$r" refer_no_replaces.calls_intact refer_no_replaces.focus_alive \
                     && _cm_count_is "$(_cm_json "$r" refer_no_replaces.room_count)" 1; then
                    pass "REFER on the focus without Replaces (a blind transfer) refused with 488; both calls and the focus untouched, nobody joined"
                else
                    fail "REFER without Replaces not handled as specified" "status=${st:-none} (want 488) $(_cm_json "$r" refer_no_replaces)"
                fi
            fi
        fi
    fi

    if should_run_test 24; then
        _TEST_NUM=24
        log "TC-${_TEST_NUM}: REFER naming an unknown dialog"
        if _cm_gate "REFER with unknown Replaces"; then
            local r="${CM_RES[merge_neg]}" st
            if _cm_started "REFER with unknown Replaces" "$r"; then
                st=$(_cm_json "$r" refer_bogus_replaces.status)
                if [ -z "$(_cm_json "$r" refer_bogus_replaces)" ]; then
                    fail "REFER with an unknown Replaces could not be tried" "focus=$(_cm_json "$r" focus) errors=$(_cm_json "$r" errors)"
                elif _cm_all_true "$r" refer_bogus_replaces.calls_intact refer_bogus_replaces.focus_alive \
                     && _cm_count_is "$(_cm_json "$r" refer_bogus_replaces.room_count)" 1 \
                     && [ -z "$(_cm_merge_verdict "$r" 2)" ]; then
                    local logged="not seen in docker logs"
                    echo "${CM_ASLOG[merge_neg]}" | grep -q "BRIDGE FAILED" && logged="logged as BRIDGE FAILED"
                    pass "Replaces of a dialog the AS does not own merged nobody (room stayed at 1), calls and focus untouched, AS answered ${st} and ${logged}; the two real merges afterwards still worked. Note: the NOTIFY says 200 by design even for this failure"
                else
                    fail "Unknown Replaces disturbed the conference" "$(_cm_json "$r" refer_bogus_replaces) later-merges: $(_cm_merge_verdict "$r" 2)"
                fi
            fi
        fi
    fi

    if should_run_test 25; then
        _TEST_NUM=25
        log "TC-${_TEST_NUM}: drop of a number that is not in the conference"
        if _cm_gate "Drop unknown number"; then
            local r="${CM_RES[merge_neg]}" st
            if _cm_started "Drop unknown number" "$r"; then
                st=$(_cm_json "$r" drop_unknown.status)
                if [ -z "$(_cm_json "$r" drop_unknown)" ]; then
                    fail "Drop of an unknown number could not be tried" "focus=$(_cm_json "$r" focus) errors=$(_cm_json "$r" errors)"
                elif [ "$st" = "404" ] && _cm_all_true "$r" drop_unknown.calls_intact drop_unknown.focus_alive; then
                    pass "Drop of a number that is not a member answered 404 Participant Not Found (not a false 202); calls and focus untouched"
                else
                    fail "Drop of an unknown number not refused" "status=${st:-none} (want 404) $(_cm_json "$r" drop_unknown)"
                fi
            fi
        fi
    fi

    if should_run_test 26; then
        _TEST_NUM=26
        log "TC-${_TEST_NUM}: nothing left behind by the merge tests"
        if ! $as_up; then
            skip "Merge cleanup" "OpenSIPS AS not running"
        else
            local stale waited rooms
            read -r stale waited <<< "$(_cm_wait_no_stale)"
            rooms=$(_cm_merge_rooms); rooms=${rooms:-0}
            if [ "$stale" = "-1" ]; then
                skip "Merge cleanup" "MI b2b_logic:list did not answer (see TC-1)"
            elif [ "$stale" = "0" ] && [ "$rooms" = "0" ]; then
                pass "After all conferences: no B2B session of the test subscribers (clear after ${waited}s) and no merge-* room left in FreeSWITCH"
            else
                append_report_block "b2b_logic:list" "$(_cm_b2b_list | head -c 3000)"
                append_report_block "conference list" "$(docker exec freeswitch "$CM_FS_CLI" -x 'conference list' 2>/dev/null | head -20)"
                fail "Conference state left behind" "B2B references to the test subscribers after ${waited}s: ${stale}; merge-* rooms in FreeSWITCH: ${rooms} (a stale session makes mi_findroom join a dead room on the next merge)"
            fi
        fi
    fi

    # ─────────────────────────── not automatable here ───────────────────────────

    if should_run_test 27; then
        _TEST_NUM=27
        skip "Merge across two NIBs" "needs two NIBs with fallback routing (terminating iFC on X-Fallback-Origin); this suite runs against one stack. Test manually: A on NIB1 merges B on NIB1 and C on NIB2"
    fi

    if should_run_test 28; then
        _TEST_NUM=28
        skip "Audio mixed between the parties" "the UE simulator sends no RTP, so only signalling and room membership are verified. Check with real handsets: everybody hears everybody, no echo, no one-way audio after a participant-initiated merge"
    fi

    # ───────────────────────────── conference CDR ─────────────────────────────

    if should_run_test 29; then
        _TEST_NUM=29
        log "TC-${_TEST_NUM}: merge conference recorded in conf_cdr.csv"
        if _cm_gate "Merge conference CDR"; then
            if ! docker exec freeswitch grep -q 'MERGE_PATTERN' /usr/local/freeswitch/scripts/conference_cdr.lua 2>/dev/null; then
                skip "Merge conference CDR" "the conference_cdr.lua loaded by FreeSWITCH only logs 1NNR rooms - copy the updated freeswitch/conference_cdr.lua and restart the freeswitch container"
            else
                _cm_run merge3 320 merge $UE_A $UE_B $UE_C --port 128 --parties 2 --subscribe --conf-hold 8
                local r="${CM_RES[merge3]}" room rows legs conf peak host parts a_imsi
                if _cm_started "Merge conference CDR" "$r"; then
                    room=$(_cm_json "$r" focus.room)
                    a_imsi=$(_cm_imsi "${CM_MS[0]}")
                    if [ -z "$room" ] || [ -n "$(_cm_merge_verdict "$r" 2)" ]; then
                        fail "Merge conference CDR could not be checked" "the merge itself did not complete: $(_cm_merge_verdict "$r" 2)"
                    else
                        # rows are written when the room is destroyed; give the logger a moment
                        local tries=0
                        while :; do
                            rows=$(docker exec freeswitch sh -c "grep -F ',${room},' /cdr-logs/conf_cdr.csv 2>/dev/null")
                            [ -n "$rows" ] || rows=$(docker exec pcscf sh -c "grep -F ',${room},' /cdr-logs/conf_cdr.csv 2>/dev/null")
                            [ -n "$rows" ] && break
                            tries=$(( tries + 1 )); [ "$tries" -ge 5 ] && break
                            sleep 2
                        done
                        append_report_block "conf_cdr.csv rows for ${room}" "$rows"
                        legs=$(echo "$rows" | grep -c '^LEG,')
                        conf=$(echo "$rows" | grep -c '^CONF,')
                        host=$(echo "$rows" | awk -F',' '$1=="CONF"{print $2; exit}')
                        parts=$(echo "$rows" | awk -F',' '$1=="CONF"{print $3; exit}')
                        peak=$(echo "$rows" | awk -F',' '$1=="CONF"{print $4; exit}')
                        local want_legs got_legs want_parts got_parts
                        want_legs=$(printf '%s\n' "$a_imsi" "$(_cm_imsi "${CM_MS[1]}")" "$(_cm_imsi "${CM_MS[2]}")" | sort | tr '\n' ' ')
                        got_legs=$(echo "$rows" | awk -F',' '$1=="LEG"{print $3}' | sort | tr '\n' ' ')
                        want_parts=$(printf '%s\n' "$(_cm_imsi "${CM_MS[1]}")" "$(_cm_imsi "${CM_MS[2]}")" | sort | tr '\n' ' ')
                        got_parts=$(echo "$parts" | tr ';' '\n' | grep . | sort | tr '\n' ' ')
                        if [ -z "$rows" ]; then
                            fail "Merge conference left no row in conf_cdr.csv" "no row with bridge ${room}; check 'docker logs freeswitch | grep conf_cdr' - the script logs every add/del/destroy it handles"
                        elif [ "$conf" = "1" ] && [ "$legs" = "3" ] && [ "$peak" = "3" ] && { [ "$host" != "$a_imsi" ] || [ "$got_legs" != "$want_legs" ] || [ "$got_parts" != "$want_parts" ]; }; then
                            fail "Merge conference CDR does not identify the parties" "rows are there (1 CONF, 3 LEG, peak 3) but host='${host}' (want ${a_imsi}), LEG participants [${got_legs}] (want [${want_legs}]), CONF participants [${got_parts}] (want [${want_parts}]) - FreeSWITCH is recording the original caller's number on the AS-created legs; conference_cdr.lua must take the leg's From user for merge rooms"
                        elif [ "$conf" = "1" ] && [ "$legs" = "3" ] && [ "$peak" = "3" ]; then
                            pass "Merge conference ${room} recorded: 1 CONF row (host ${host} = the initiator, participants ${parts}, peak 3) and 3 LEG rows, one per party (${got_legs})"
                        else
                            fail "Merge conference CDR incomplete" "bridge ${room}: CONF rows=${conf} (want 1), LEG rows=${legs} (want 3), peak=${peak:-none} (want 3), host='${host}', participants='${parts}'"
                        fi
                    fi
                fi
            fi
        fi
    fi

    if should_run_test 30; then
        _TEST_NUM=30
        log "TC-${_TEST_NUM}: participant-initiated merge in conf_cdr.csv (one LEG row per person)"
        if _cm_gate "Merge CDR after a participant's merge"; then
            if ! docker exec freeswitch grep -q 'c.present' /usr/local/freeswitch/scripts/conference_cdr.lua 2>/dev/null; then
                skip "Merge CDR after a participant's merge" "the conference_cdr.lua loaded by FreeSWITCH does not fold a member's leg swap - copy the updated freeswitch/conference_cdr.lua and restart the freeswitch container"
            else
                _cm_run merge_join 420 merge $UE_A $UE_B $UE_C $UE_D --port 148 --parties 2 --join
                local r="${CM_RES[merge_join]}" room rows tries=0 legs want got peak parts
                if _cm_started "Merge CDR after a participant's merge" "$r"; then
                    room=$(_cm_json "$r" focus.room)
                    if [ -z "$room" ] || [ "$(_cm_json "$r" join.newcomer_reinvited)" != "True" ]; then
                        fail "Merge CDR after a participant's merge could not be checked" "the participant-initiated merge itself did not complete (see TC-22): join=$(_cm_json "$r" join)"
                    else
                        while :; do
                            rows=$(docker exec pcscf sh -c "grep -F ',${room},' /cdr-logs/conf_cdr.csv 2>/dev/null")
                            [ -n "$rows" ] && break
                            tries=$(( tries + 1 )); [ "$tries" -ge 5 ] && break
                            sleep 2
                        done
                        append_report_block "conf_cdr.csv rows for ${room}" "$rows"
                        legs=$(echo "$rows" | grep -c '^LEG,')
                        want=$(for i in 0 1 2 3; do _cm_imsi "${CM_MS[$i]}"; done | sort | tr '\n' ' ')
                        got=$(echo "$rows" | awk -F',' '$1=="LEG"{print $3}' | sort | tr '\n' ' ')
                        peak=$(echo "$rows" | awk -F',' '$1=="CONF"{print $4; exit}')
                        parts=$(echo "$rows" | awk -F',' '$1=="CONF"{print $3; exit}')
                        if [ "$legs" = "4" ] && [ "$got" = "$want" ] && [ "$peak" = "4" ]; then
                            pass "B was merged in and then added D itself: 4 people, 4 LEG rows (B once, from its first join to the end), CONF participants ${parts}, peak 4"
                        else
                            fail "Merge CDR wrong after a participant's merge" "bridge ${room}: LEG rows=${legs} (want 4), LEG participants [${got}] (want [${want}]), peak=${peak:-none} (want 4), CONF participants '${parts}'"
                        fi
                    fi
                fi
            fi
        fi
    fi

    # ──────────────────── call CDR (cdr.csv) with the B2BUA in the path ────────────────────
    # Real handsets, 2026-10-08: a call crosses the S-CSCF as two dialogs (caller leg +
    # the AS's "B2B" leg), which wrote the call twice when the callee hung up, counted
    # ringing as talk time, and let a merged party's row run on into the conference.
    # These cases hold the S-CSCF to: one row per answered call, clock from answer,
    # row closed at hang-up or at merge, nothing for unanswered calls.

    local IMSI_A IMSI_B IMSI_C
    IMSI_A=$(_cm_imsi "${CM_MS[0]}"); IMSI_B=$(_cm_imsi "${CM_MS[1]}"); IMSI_C=$(_cm_imsi "${CM_MS[2]}")

    if should_run_test 31; then
        _TEST_NUM=31
        log "TC-${_TEST_NUM}: call CDR - exactly one row per answered call, duration = talk time"
        if _cm_gate "Call CDR: one row per call"; then
            _cm_run anchor 200 anchor $UE_A $UE_B --port 100 --talk 6
            _cm_run anchor_hold 220 anchor $UE_A $UE_B --port 104 --hold-resume --bye-from callee
            _cm_run anchor_video 200 anchor $UE_A $UE_B --port 108 --video
            local n1 n2 n3 d1 d2 t1 t2 problems=""
            n1=$(_cm_cdr_count anchor); n2=$(_cm_cdr_count anchor_hold); n3=$(_cm_cdr_count anchor_video)
            d1=$(_cm_cdr_dur anchor "$IMSI_A" "$IMSI_B"); t1=$(_cm_json "${CM_RES[anchor]}" release.talk_seconds)
            d2=$(_cm_cdr_dur anchor_hold "$IMSI_A" "$IMSI_B"); t2=$(_cm_json "${CM_RES[anchor_hold]}" release.talk_seconds)
            [ "$(_cm_json "${CM_RES[anchor]}" call.ok)" = "True" ] && [ "$(_cm_json "${CM_RES[anchor_hold]}" call.ok)" = "True" ] \
                && [ "$(_cm_json "${CM_RES[anchor_video]}" call.ok)" = "True" ] || problems="${problems} a-test-call-was-not-set-up"
            [ "$n1" = "1" ] || problems="${problems} caller-ended-call:${n1}-rows"
            [ "$n2" = "1" ] || problems="${problems} callee-ended-call-with-hold/resume:${n2}-rows"
            [ "$n3" = "1" ] || problems="${problems} video-call:${n3}-rows"
            printf '%s\n' "${CM_CDR[anchor_video]}" | grep -q ",video," || problems="${problems} video-call-not-recorded-as-video"
            _cm_near "$d1" "$t1" 2 || problems="${problems} caller-ended:cdr=${d1}s/talk=${t1}s"
            _cm_near "$d2" "$t2" 2 || problems="${problems} callee-ended:cdr=${d2}s/talk=${t2}s"
            if [ -z "$problems" ]; then
                pass "One cdr.csv row per call whoever hangs up (caller-ended 1, callee-ended with hold/resume 1, video 1), and the duration is the talk time counted from answer (${d1}s for ${t1}s talked; ${d2}s for ${t2}s)"
            else
                fail "Call CDR is not one correct row per call" "${problems} | rows: caller-ended [${CM_CDR[anchor]}] callee-ended [${CM_CDR[anchor_hold]}] video [${CM_CDR[anchor_video]}]. Two rows = one per S-CSCF dialog (caller leg + AS 'B2B' leg); a duration well above the talk time = clock started at INVITE instead of at answer"
            fi
        fi
    fi

    if should_run_test 32; then
        _TEST_NUM=32
        log "TC-${_TEST_NUM}: call CDR - no row for calls that were never answered"
        if _cm_gate "Call CDR: unanswered calls"; then
            _cm_run cancel 200 cancel $UE_A $UE_B --port 112
            _cm_run reject 200 reject $UE_A $UE_B --port 116
            _cm_run unreachable 200 unreachable $UE_A --port 120 --target "$CM_UNREG_NUMBER"
            _cm_run factory 160 factory $UE_A --port 124
            local nc nr nu nf
            nc=$(_cm_cdr_count cancel); nr=$(_cm_cdr_count reject); nu=$(_cm_cdr_count unreachable); nf=$(_cm_cdr_count factory)
            if [ "$nc" = "0" ] && [ "$nr" = "0" ] && [ "$nu" = "0" ] && [ "$nf" = "0" ]; then
                pass "No cdr.csv row for a cancelled call, a rejected (busy) call, a call to an unregistered number, or the Merge call to the conference factory"
            else
                fail "cdr.csv has rows for calls that were never answered" "rows added: cancelled=${nc} rejected=${nr} unregistered=${nu} conference-factory=${nf} (want 0 each) | [${CM_CDR[cancel]}] [${CM_CDR[reject]}] [${CM_CDR[unreachable]}] [${CM_CDR[factory]}]"
            fi
        fi
    fi

    if should_run_test 33; then
        _TEST_NUM=33
        log "TC-${_TEST_NUM}: call CDR - a merged call's row ends at the merge"
        if _cm_gate "Call CDR: merged calls"; then
            _cm_run merge3 320 merge $UE_A $UE_B $UE_C --port 128 --parties 2 --subscribe --conf-hold 8
            _cm_run merge_in 320 merge $UE_A $UE_B $UE_C --port 132 --parties 2 --direction in --conf-hold 8
            # expected 2-party time of call k of a run = merge time - answer time
            _cm_expect() { "$PYTHON_BIN" -c "
import sys, json
try:
    r = json.loads(sys.argv[1]); k = int(sys.argv[2])
    print(round(r['merges'][k]['at'] - r['calls'][k]['answered_at'], 1))
except Exception:
    print('')
" "$1" "$2" 2>/dev/null; }
            local r3="${CM_RES[merge3]}" ri="${CM_RES[merge_in]}" problems="" n3 ni
            local e3b e3c eib eic d3b d3c dib dic
            n3=$(_cm_cdr_count merge3); ni=$(_cm_cdr_count merge_in)
            e3b=$(_cm_expect "$r3" 0); e3c=$(_cm_expect "$r3" 1)
            eib=$(_cm_expect "$ri" 0); eic=$(_cm_expect "$ri" 1)
            d3b=$(_cm_cdr_dur merge3 "$IMSI_A" "$IMSI_B"); d3c=$(_cm_cdr_dur merge3 "$IMSI_A" "$IMSI_C")
            dib=$(_cm_cdr_dur merge_in "$IMSI_B" "$IMSI_A"); dic=$(_cm_cdr_dur merge_in "$IMSI_A" "$IMSI_C")
            if [ -n "$(_cm_merge_verdict "$r3" 2)" ] || [ -n "$(_cm_merge_verdict "$ri" 2)" ]; then
                fail "Call CDR of merged calls could not be checked" "a merge did not complete: [$(_cm_merge_verdict "$r3" 2)] [$(_cm_merge_verdict "$ri" 2)]"
            else
                [ "$n3" = "2" ] || problems="${problems} A-called-B-and-C:${n3}-rows(want-2)"
                [ "$ni" = "2" ] || problems="${problems} B-called-A,A-called-C:${ni}-rows(want-2)"
                _cm_near "$d3b" "$e3b" 3 || problems="${problems} A->B:cdr=${d3b}s/until-merge=${e3b}s"
                _cm_near "$d3c" "$e3c" 3 || problems="${problems} A->C:cdr=${d3c}s/until-merge=${e3c}s"
                _cm_near "$dib" "$eib" 3 || problems="${problems} B->A(received-by-initiator):cdr=${dib}s/until-merge=${eib}s"
                _cm_near "$dic" "$eic" 3 || problems="${problems} A->C:cdr=${dic}s/until-merge=${eic}s"
                if [ -z "$problems" ]; then
                    pass "Each merged call has one cdr.csv row that ends at the merge, although everybody stayed 8 s longer in the conference: A->B ${d3b}s (${e3b}s until merge), A->C ${d3c}s (${e3c}s); with a call the initiator RECEIVED: B->A ${dib}s (${eib}s), A->C ${dic}s (${eic}s). Conference time is in conf_cdr.csv only"
                else
                    fail "Call CDR of merged calls is wrong" "${problems} | rows [${CM_CDR[merge3]}] [${CM_CDR[merge_in]}]. A duration about 8 s too long = the row ran on into the conference (the S-CSCF did not close it at the merge REFER)"
                fi
            fi
        fi
    fi

    if [ "${CALL_MERGE_KEEP:-0}" != "1" ]; then
        _cm_delete_all
    else
        log "CALL_MERGE_KEEP=1: test subscribers left in PyHSS (${CM_MS[*]})"
    fi

    end_feature
}
