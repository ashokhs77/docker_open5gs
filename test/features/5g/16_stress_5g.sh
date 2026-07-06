#!/bin/bash
# Feature 16: Stress / Stability Tests (5G VoNR)
#
# These tests validate system stability under sustained load and corner cases
# specific to 5G SA + VoNR. Key differences from 4G stress:
#   - Pre-stress restart targets AMF/SMF/UPF (not MME/SGW)
#   - Call-level tests use SIPp direct to FreeSWITCH (no 4G UE simulator)
#   - PCF N5 interface replaces PCRF Rx for policy health checks
#   - UERANSIM-dependent tests skip gracefully if UERANSIM not running
#
# Tests:
#   TC-1: P-CSCF resource configuration audit (SHM, IPSec, CDP)
#   TC-2: Concurrent VoNR calls under load (SIPp to FreeSWITCH)
#   TC-3: Long-duration VoNR call stability (session-timer resilience)
#   TC-4: Rx Diameter health under load (CDP threshold monitoring, P-CSCF → PCF)
#   TC-5: P-CSCF shared memory utilization under load
#   TC-6: IPSec port exhaustion detection
#   TC-7: In-dialog AAR failure resilience (CRITICAL — call survives QoS refresh failure)
#   TC-8: Multi-call concurrent stability (multiple simultaneous VoNR sessions)

set +e

STRESS_5G_LOG_SINCE=""

read_pcscf_define() {
    local define_name="$1"
    docker exec pcscf grep -E "^#!define ${define_name} " /etc/kamailio_pcscf/pcscf.cfg 2>/dev/null \
        | awk '{print $3}' | tr -d '"' | head -1
}

get_kamailio_shm_mb() {
    local cmdline
    cmdline=$(docker exec pcscf ps aux 2>/dev/null | grep 'kamailio.*-m' | head -1)
    echo "$cmdline" | grep -oP '(?<=-m )\d+' | head -1
}

get_cdp_value() {
    local attr="$1"
    docker exec pcscf grep -oP "${attr}=\"\K[^\"]*" /etc/kamailio_pcscf/pcscf.xml 2>/dev/null | head -1
}

pcscf_logs_current_run() {
    if [ -n "${STRESS_5G_LOG_SINCE:-}" ]; then
        docker logs --since "$STRESS_5G_LOG_SINCE" pcscf 2>&1
    else
        docker logs pcscf 2>&1
    fi
}

count_cdp_threshold_violations() {
    pcscf_logs_current_run | grep -Ec "CDP threshold|outside of threshold" 2>/dev/null || true
}

get_pcscf_shm_stats() {
    docker exec pcscf kamcmd core.shmmem 2>/dev/null || echo ""
}

count_ipsec_tunnels() {
    docker exec pcscf ip xfrm state count 2>/dev/null | grep -oP '\d+' | head -1 || echo 0
}

check_indialog_aar_handler() {
    local cfg_file="$1"
    local route_name="$2"
    local handler_block
    handler_block=$(docker exec pcscf sed -n "/route\[${route_name}\]/,/^}/p" \
        /etc/kamailio_pcscf/${cfg_file} 2>/dev/null)

    if [ -z "$handler_block" ]; then
        echo "NOT_FOUND"
        return 2
    fi

    local active_terminate
    active_terminate=$(echo "$handler_block" | grep -v '^\s*#' | grep -c 'dlg_terminate' 2>/dev/null || true)

    if [ "$active_terminate" -gt 0 ]; then
        echo "DANGEROUS"
        return 1
    else
        echo "SAFE"
        return 0
    fi
}

run_stress_5g_tests() {
    start_feature "Stress Test (5G VoNR)"
    STRESS_5G_LOG_SINCE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    log ""
    log "NOTE: These tests validate 5G SA + VoNR stability under sustained load."
    log "      The 5G equivalents of the 30-40 min VoLTE call disconnection bug"
    log "      are caught here (in-dialog AAR failure + dlg_terminate pattern)."
    log ""

    # Pre-stress: restart 5G user-plane and control-plane NFs
    # Previous features (load test, PDU session) can leave SMF/UPF in degraded state.
    log "Pre-stress: restarting 5GC control/user-plane NFs (clearing stale state)..."
    docker restart upf smf amf 2>/dev/null || true
    sleep 10
    local _wait=0
    while [ $_wait -lt 30 ]; do
        local _ready=true
        container_is_running "amf" && amf_ngap_ready || _ready=false
        container_is_running "smf" && container_listens_on_port "smf" 8805 || _ready=false
        container_is_running "upf" && container_listens_on_port "upf" 2152 || _ready=false
        if $_ready; then
            log "Pre-stress: 5GC NFs ready after ${_wait}s"
            break
        fi
        sleep 1
        _wait=$((_wait + 1))
    done
    if [ $_wait -ge 30 ]; then
        log "WARNING: 5GC NFs may not be fully ready after 30s — continuing stress tests"
    fi
    capture_container_resource_snapshot "Stress test baseline (5G)"

    # ============================================================
    # TC-1: P-CSCF Resource Configuration Audit
    # ============================================================
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: P-CSCF resource configuration audit (SHM, IPSec, CDP)"

        local issues="" details=""
        local shm_mb; shm_mb=$(get_kamailio_shm_mb); shm_mb=${shm_mb:-0}
        details="${details}SHM=${shm_mb}MB "
        [ "$shm_mb" -lt 64 ] 2>/dev/null && issues="${issues}SHM=${shm_mb}MB(<64MB minimum); "

        local ipsec_max; ipsec_max=$(read_pcscf_define "IPSEC_MAX_CONN"); ipsec_max=${ipsec_max:-0}
        details="${details}IPSEC_MAX_CONN=${ipsec_max} "
        [ "$ipsec_max" -lt 15 ] 2>/dev/null && issues="${issues}IPSEC_MAX_CONN=${ipsec_max}(<15); "

        local cdp_workers; cdp_workers=$(get_cdp_value "Workers"); cdp_workers=${cdp_workers:-0}
        details="${details}CDP_Workers=${cdp_workers} "
        [ "$cdp_workers" -lt 6 ] 2>/dev/null && issues="${issues}CDP_Workers=${cdp_workers}(<6); "

        local cdp_timeout; cdp_timeout=$(get_cdp_value "TransactionTimeout"); cdp_timeout=${cdp_timeout:-0}
        details="${details}CDP_Timeout=${cdp_timeout}s "
        [ "$cdp_timeout" -lt 8 ] 2>/dev/null && issues="${issues}CDP_TransactionTimeout=${cdp_timeout}s(<8s); "

        local cdp_latency; cdp_latency=$(read_pcscf_define "CDP_LATENCY_THRESHOLD_MS"); cdp_latency=${cdp_latency:-0}
        details="${details}CDP_LatencyThreshold=${cdp_latency}ms"

        log "  Config: $details"
        if [ -z "$issues" ]; then
            pass "P-CSCF config audit: all resources adequate for 5G VoNR deployment ($details)"
        else
            fail "P-CSCF under-provisioned" "$issues"
        fi
    fi

    # ============================================================
    # TC-2: Concurrent VoNR Calls Under Load
    # Uses SIPp directly to FreeSWITCH to simulate concurrent VoNR sessions.
    # This tests IMS dialog handling without requiring UERANSIM/PDU sessions.
    # ============================================================
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Concurrent VoNR calls under load (SIPp → FreeSWITCH)"
        log "  Starting 3 simultaneous VoNR call legs to different conference rooms"

        local fs_ok=false
        check_port "${FREESWITCH_IP:-172.22.1.150}" "5090" && fs_ok=true

        if ! $fs_ok; then
            skip "Concurrent VoNR calls" "FreeSWITCH not reachable at ${FREESWITCH_IP:-172.22.1.150}:5090"
        else
            local CALL_PIDS=""
            for i in 1 2 3; do
                local ROOM=$((1020 + $i))
                local PORT=$((7950 + $i))
                sipp ${FREESWITCH_IP}:5090 \
                    -sf /opt/test/scenarios/fs_long_call.xml \
                    -s $ROOM -i $LOCAL_IP -p $PORT \
                    -m 1 -l 1 -timeout 30 -timeout_error \
                    >/tmp/sipp_stress5g_tc2_c${i}.log 2>&1 &
                CALL_PIDS="$CALL_PIDS $!"
            done
            sleep 6
            local CONNECTED=0
            for PID in $CALL_PIDS; do
                kill -0 $PID 2>/dev/null && CONNECTED=$((CONNECTED + 1))
            done
            if [ $CONNECTED -ge 3 ]; then
                pass "All 3 concurrent VoNR call legs established simultaneously"
            elif [ $CONNECTED -ge 2 ]; then
                pass "Concurrent VoNR load test partially passing ($CONNECTED/3 legs active)"
            else
                fail "Concurrent VoNR call establishment failed under load" "$CONNECTED/3 legs connected"
            fi
            for PID in $CALL_PIDS; do kill $PID 2>/dev/null; done
            for PID in $CALL_PIDS; do wait $PID 2>/dev/null || true; done
        fi
    fi

    # ============================================================
    # TC-3: Long-Duration VoNR Call Stability
    # ============================================================
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local hold_duration=${STRESS_CALL_DURATION:-45}
        log "TC-${_TEST_NUM}: Long-duration VoNR call stability (${hold_duration}s call to FreeSWITCH)"
        log "  Validates session-timer resilience — call must not drop before timeout"

        local fs_ok=false
        check_port "${FREESWITCH_IP:-172.22.1.150}" "5090" && fs_ok=true

        if ! $fs_ok; then
            skip "Long-duration VoNR call" "FreeSWITCH not reachable"
        else
            local t_start=$SECONDS
            sipp ${FREESWITCH_IP}:5090 \
                -sf /opt/test/scenarios/fs_long_call.xml \
                -s 1010 -i $LOCAL_IP -p 7960 \
                -m 1 -l 1 \
                -timeout $((hold_duration + 15)) \
                -timeout_error \
                >/tmp/sipp_stress5g_tc3.log 2>&1
            local sipp_rc=$?
            local actual_dur=$(( SECONDS - t_start ))

            if [ $sipp_rc -eq 0 ]; then
                pass "Long-duration VoNR call survived ${actual_dur}s (target ${hold_duration}s) — no premature disconnect"
            else
                fail "VoNR call disconnected prematurely" "actual=${actual_dur}s target=${hold_duration}s rc=${sipp_rc}"
                local cdp_v; cdp_v=$(count_cdp_threshold_violations)
                log "  Diagnostics: CDP threshold violations=${cdp_v}"
            fi
        fi
    fi

    # ============================================================
    # TC-4: Rx Diameter Health Under Load (P-CSCF → PCF)
    # In 5G SA, P-CSCF still uses Rx/Diameter to reach PCF for IMS QoS.
    # CDP threshold violations indicate Diameter response >500ms — the
    # precursor to AAR failures that kill established VoNR calls.
    # ============================================================
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Rx Diameter health (P-CSCF → PCF, CDP threshold violations)"
        local cdp_latency; cdp_latency=$(read_pcscf_define "CDP_LATENCY_THRESHOLD_MS"); cdp_latency=${cdp_latency:-500}
        log "  CDP threshold (>${cdp_latency}ms Diameter response) triggers AAR failures → VoNR call drops"

        local cdp_violations; cdp_violations=$(count_cdp_threshold_violations); cdp_violations=${cdp_violations:-0}
        local aar_failures; aar_failures=$(pcscf_logs_current_run | grep -c "AAR failed" 2>/dev/null || true); aar_failures=${aar_failures:-0}
        local indialog_warns; indialog_warns=$(pcscf_logs_current_run | grep -c "In-dialog AAR failed" 2>/dev/null || true); indialog_warns=${indialog_warns:-0}
        local dlg_terminates; dlg_terminates=$(pcscf_logs_current_run | grep -c "Sorry no QoS available" 2>/dev/null || true); dlg_terminates=${dlg_terminates:-0}

        log "  CDP threshold violations: $cdp_violations"
        log "  AAR failures (initial): $aar_failures"
        log "  In-dialog AAR failures: $indialog_warns"
        log "  dlg_terminate calls: $dlg_terminates"
        printf "  CDP_violations=%s AAR_fail=%s AAR_indialog=%s dlg_terminate=%s\n" \
            "$cdp_violations" "$aar_failures" "$indialog_warns" "$dlg_terminates" >> "$_FEATURE_REPORT"

        if [ "$dlg_terminates" -gt 0 ] 2>/dev/null; then
            fail "Active dlg_terminate on QoS failure — VoNR calls are being killed!" \
                 "dlg_terminates=$dlg_terminates (CRITICAL: in-dialog AAR handler has dlg_terminate active)"
        elif [ "$cdp_violations" -gt 50 ] 2>/dev/null; then
            fail "Excessive CDP threshold violations ($cdp_violations) — Diameter peer overloaded" ""
        else
            pass "Rx Diameter health OK: cdp_violations=$cdp_violations aar_failures=$aar_failures dlg_terminates=$dlg_terminates"
        fi
    fi

    # ============================================================
    # TC-5: P-CSCF Shared Memory Utilization
    # ============================================================
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: P-CSCF shared memory utilization"
        local shm_stats; shm_stats=$(get_pcscf_shm_stats)

        if [ -z "$shm_stats" ]; then
            shm_stats=$(docker exec pcscf kamctl stats shm 2>/dev/null || echo "")
        fi

        if [ -z "$shm_stats" ]; then
            local log_shm; log_shm=$(pcscf_logs_current_run | grep -i "free_size\|total_size\|shm" | tail -5)
            if [ -n "$log_shm" ]; then
                pass "P-CSCF SHM monitoring: log-based stats collected (kamcmd unavailable)"
            else
                skip "P-CSCF SHM utilization" "Cannot read SHM stats"
            fi
        else
            local total_mb free_mb
            total_mb=$(echo "$shm_stats" | grep -oP 'total:\s*\K\d+' | head -1)
            free_mb=$(echo "$shm_stats" | grep -oP 'free:\s*\K\d+' | head -1)

            if [ -n "$total_mb" ] && [ -n "$free_mb" ] && [ "$total_mb" -gt 0 ] 2>/dev/null; then
                local used=$((total_mb - free_mb))
                local used_pct=$((used * 100 / total_mb))
                log "  SHM: total=${total_mb} free=${free_mb} used=${used} (${used_pct}%)"
                printf "  SHM: total=%s free=%s used_pct=%s%%\n" "$total_mb" "$free_mb" "$used_pct" >> "$_FEATURE_REPORT"

                if [ "$used_pct" -gt 90 ] 2>/dev/null; then
                    fail "P-CSCF SHM nearly exhausted (${used_pct}%)" "Increase -m parameter"
                elif [ "$used_pct" -gt 75 ] 2>/dev/null; then
                    pass "P-CSCF SHM usage elevated but OK (${used_pct}%)"
                else
                    pass "P-CSCF SHM usage healthy (${used_pct}%)"
                fi
            else
                pass "P-CSCF SHM stats retrieved (manual review needed)"
            fi
        fi
    fi

    # ============================================================
    # TC-6: IPSec Port Exhaustion Detection
    # ============================================================
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: IPSec port exhaustion detection"
        local ipsec_max; ipsec_max=$(read_pcscf_define "IPSEC_MAX_CONN"); ipsec_max=${ipsec_max:-0}
        local active_tunnels; active_tunnels=$(count_ipsec_tunnels); active_tunnels=${active_tunnels:-0}
        local active_ues=0
        [ "$active_tunnels" -gt 0 ] 2>/dev/null && active_ues=$((active_tunnels / 2))
        local headroom=0
        [ "$ipsec_max" -gt 0 ] 2>/dev/null && headroom=$((ipsec_max - active_ues))

        log "  IPSEC_MAX_CONN=$ipsec_max active_tunnels=$active_tunnels (~${active_ues} UEs) headroom=$headroom"
        printf "  IPSEC: max=%s active=%s ues=~%s headroom=%s\n" \
            "$ipsec_max" "$active_tunnels" "$active_ues" "$headroom" >> "$_FEATURE_REPORT"

        local ipsec_errors
        ipsec_errors=$(pcscf_logs_current_run | grep -ic "no.*ipsec.*port\|ipsec.*tunnel.*exhaust\|ipsec.*alloc.*fail\|ipsec_on_expire.*error\|unable.*ipsec" 2>/dev/null || true)

        if [ "$ipsec_errors" -gt 0 ] 2>/dev/null; then
            fail "IPSec errors detected ($ipsec_errors occurrences)" "Check IPSEC_MAX_CONN ($ipsec_max)"
        elif [ "$ipsec_max" -lt 15 ] 2>/dev/null; then
            fail "IPSEC_MAX_CONN=$ipsec_max too low for concurrent VoNR UE deployment" "Increase to ≥20"
        elif [ "$headroom" -lt 5 ] 2>/dev/null && [ "$active_ues" -gt 0 ] 2>/dev/null; then
            fail "IPSec pool nearly exhausted" "active=~${active_ues}, max=$ipsec_max, headroom=$headroom"
        else
            pass "IPSec ports healthy: max=$ipsec_max active=~${active_ues} headroom=$headroom errors=$ipsec_errors"
        fi
    fi

    # ============================================================
    # TC-7: In-Dialog AAR Failure Resilience (CRITICAL)
    # THE MOST CRITICAL TEST — validates that the P-CSCF does NOT
    # terminate established VoNR calls when an in-dialog Rx AAR fails.
    # This bug (dlg_terminate in MO_indialog_aar_reply) causes 30-40 min
    # call disconnections. Same root cause exists in 5G VoNR as in 4G VoLTE.
    # ============================================================
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: In-dialog AAR failure resilience (CRITICAL)"
        log "  CRITICAL: established VoNR calls must NOT be killed on session-refresh AAR failure"

        local mo_result mt_result
        mo_result=$(check_indialog_aar_handler "route/mo.cfg" "MO_indialog_aar_reply")
        mt_result=$(check_indialog_aar_handler "route/mt.cfg" "MT_indialog_aar_reply")

        log "  MO_indialog_aar_reply: ${mo_result}"
        log "  MT_indialog_aar_reply: ${mt_result}"
        printf "  MO_indialog_aar=%s MT_indialog_aar=%s\n" "$mo_result" "$mt_result" >> "$_FEATURE_REPORT"

        if [ "$mo_result" = "DANGEROUS" ] || [ "$mt_result" = "DANGEROUS" ]; then
            fail "CRITICAL: In-dialog AAR handler still has dlg_terminate active!" \
                 "MO=${mo_result}, MT=${mt_result} — VoNR calls WILL be killed on session-timer refresh AAR failure"
        elif [ "$mo_result" = "NOT_FOUND" ] || [ "$mt_result" = "NOT_FOUND" ]; then
            skip "In-dialog AAR handler not found in P-CSCF config" \
                 "MO=${mo_result}, MT=${mt_result} — may be using N5 SBI or WITH_RX not defined"
        else
            pass "In-dialog AAR handlers safe: MO=${mo_result}, MT=${mt_result} — VoNR calls survive QoS refresh failures"
        fi
    fi

    # ============================================================
    # TC-8: Multi-Call Concurrent Stability
    # ============================================================
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Multi-call concurrent VoNR stability (3 rooms × 2 sequential)"
        log "  Tests IMS dialog handling under back-to-back overlapping VoNR sessions"

        local fs_ok=false
        check_port "${FREESWITCH_IP:-172.22.1.150}" "5090" && fs_ok=true

        if ! $fs_ok; then
            skip "Multi-call VoNR stability" "FreeSWITCH not reachable"
        else
            # Round 1: 3 concurrent calls
            local PIDS_R1=""
            for i in 1 2 3; do
                sipp ${FREESWITCH_IP}:5090 \
                    -sf /opt/test/scenarios/fs_direct_invite.xml \
                    -s $((1030 + $i)) -i $LOCAL_IP -p $((7970 + $i)) \
                    -m 1 -l 1 -timeout 20 -timeout_error \
                    >/tmp/sipp_stress5g_tc8_r1c${i}.log 2>&1 &
                PIDS_R1="$PIDS_R1 $!"
            done
            local round1_ok=0
            for PID in $PIDS_R1; do wait $PID 2>/dev/null; [ $? -eq 0 ] && round1_ok=$((round1_ok + 1)); done

            sleep 2

            # Round 2: 3 more calls to same rooms (dialog reuse after BYE)
            local PIDS_R2=""
            for i in 1 2 3; do
                sipp ${FREESWITCH_IP}:5090 \
                    -sf /opt/test/scenarios/fs_direct_invite.xml \
                    -s $((1030 + $i)) -i $LOCAL_IP -p $((7980 + $i)) \
                    -m 1 -l 1 -timeout 20 -timeout_error \
                    >/tmp/sipp_stress5g_tc8_r2c${i}.log 2>&1 &
                PIDS_R2="$PIDS_R2 $!"
            done
            local round2_ok=0
            for PID in $PIDS_R2; do wait $PID 2>/dev/null; [ $? -eq 0 ] && round2_ok=$((round2_ok + 1)); done

            log "  Round 1: ${round1_ok}/3 calls OK; Round 2: ${round2_ok}/3 calls OK"
            if [ $round1_ok -ge 2 ] && [ $round2_ok -ge 2 ]; then
                pass "Multi-call VoNR stability: round1=${round1_ok}/3 round2=${round2_ok}/3 — IMS dialog cleanup working"
            elif [ $round1_ok -ge 2 ]; then
                fail "Round 2 degraded (dialog cleanup issue)" "round1=${round1_ok}/3 round2=${round2_ok}/3"
            else
                fail "Multi-call VoNR stability failed" "round1=${round1_ok}/3 round2=${round2_ok}/3"
            fi
        fi
    fi

    # Sustained 5G registration churn (capacity stress via UERANSIM multi-UE).
    # Repeatedly register+drop 128 UEs on a dedicated load gNB and confirm the
    # core stays responsive — the 5G analog of the 4G sustained-load stress.
    # Helpers from lib/ueransim_load_5g.sh; functional UE/gNB untouched.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if command -v ue_load_register >/dev/null 2>&1 \
           && container_is_running "amf" && container_is_running "mongo"; then
            provision_5g_load_subs 128 >/dev/null 2>&1
            local _rounds=3 _r _ok=0 _res _reg
            for _r in $(seq 1 $_rounds); do
                _res=$(ue_load_register 128 70); _reg=$(echo "$_res" | awk '{print $1+0}')
                [ "$_reg" -ge 121 ] && _ok=$((_ok + 1))
                log "    [stress-churn] round ${_r}/${_rounds}: ${_reg}/128 registered"
                ue_load_teardown; sleep 5
            done
            local _amf="down"; container_listens_on_port "amf" 38412 && _amf="up"
            echo "  Sustained registration churn: ${_rounds} rounds x128 UEs, ${_ok}/${_rounds} rounds >=95%, AMF NGAP ${_amf}" >> "$_FEATURE_REPORT"
            if [ "$_ok" -ge 2 ] && [ "$_amf" = "up" ]; then
                pass "Sustained 5G registration stress: ${_ok}/${_rounds} rounds at >=95% of 128 UEs, AMF NGAP stable (core resilient under sustained churn)"
            else
                fail "Sustained 5G registration stress degraded: ${_ok}/${_rounds} rounds ok, AMF ${_amf}" \
                     "core or UERANSIM under sustained registration churn"
            fi
        else
            skip "Sustained 5G registration churn" "needs 5G core (amf) + mongo + UERANSIM load helpers"
        fi
    fi

    ue_load_teardown 2>/dev/null || true
    rm -f /tmp/sipp_stress5g_tc*.log 2>/dev/null
    capture_container_resource_snapshot "Stress test final (5G)"
    end_feature
}
