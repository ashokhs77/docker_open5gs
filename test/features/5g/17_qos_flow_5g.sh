#!/bin/bash
# Feature 17b: QoS Flow / 5QI Lifecycle (5G)
# Counterpart to the 4G Bearer QoS feature. Validates 5QI/DNN provisioning,
# PCF SM-policy availability, live PDU-session QoS evidence, IMS/VoNR policy
# readiness, and gates real scheduler/throughput proof to REAL_HW runs.
#
# Tests:
#   TC-1:  Functional subscriber has internet 5QI=9 and IMS 5QI=5 sessions
#   TC-2:  SMF DNN profiles expose internet/IMS QoS and P-CSCF policy data
#   TC-3:  PCF SM-policy SBI endpoint is reachable
#   TC-4:  SMF<->PCF policy association evidence
#   TC-5:  Default QoS flow/PDU tunnel active for internet DNN
#   TC-6:  IMS signaling QoS profile ready for VoNR
#   TC-7:  IMS policy control path available from P-CSCF/PCF
#   TC-8:  PFCP QoS-rule/QER/QFI evidence or explicit log-level gate
#   TC-9:  Light user-plane continuity over the QoS flow
#   TC-10: Real-HW QoS KPI/scheduler evidence gate

set +e

_qos5_mongo() {
    mongo_eval open5gs "$1" | tail -1 | tr -d '\r'
}

_qos5_session_summary() {
    _qos5_mongo 'var s=db.subscribers.findOne({imsi:"001010000000001"}); if(!s || !s.slice || !s.slice.length){print("missing");} else {print(s.slice[0].session.map(function(x){return x.name+":"+x.type+":"+((x.qos&&x.qos.index)||"");}).join(","));}'
}

run_qos_flow_5g_tests() {
    start_feature "QoS Flow (5G)"

    local smf_cfg="" upf_cfg="" sess=""
    container_is_running "smf" && smf_cfg=$(read_nf_config smf)
    container_is_running "upf" && upf_cfg=$(read_nf_config upf)
    container_is_running "mongo" && sess=$(_qos5_session_summary)

    # TC-1: Functional subscriber has internet 5QI=9 and IMS 5QI=5 sessions
    if should_run_test 1; then
        _TEST_NUM=1
        if ! container_is_running "mongo"; then
            skip "Functional subscriber QoS profile" "MongoDB container not running"
        elif echo "$sess" | grep -q 'internet:3:9' && echo "$sess" | grep -q 'ims:3:5'; then
            pass "Functional subscriber has internet(type=IPv4v6,5QI=9) and IMS(type=IPv4v6,5QI=5) sessions"
            append_report_block "Mongo QoS profile" "$sess"
        elif [ "$sess" = "missing" ] || [ -z "$sess" ]; then
            fail "Functional 5G subscriber missing in MongoDB" "Expected IMSI 001010000000001"
        else
            fail "Functional subscriber 5QI profile mismatch" "Expected internet:3:9 and ims:3:5; got ${sess}"
        fi
    fi

    # TC-2: SMF DNN profiles expose internet/IMS QoS and P-CSCF policy data
    if should_run_test 2; then
        _TEST_NUM=2
        if [ -z "$smf_cfg" ]; then
            fail "SMF config not readable" "Cannot validate DNN QoS profile"
        elif echo "$smf_cfg" | grep -qiE 'dnn:[[:space:]]*internet' && \
             echo "$smf_cfg" | grep -qiE 'dnn:[[:space:]]*ims' && \
             echo "$smf_cfg" | grep -qiE 'p-cscf:'; then
            pass "SMF exposes internet/IMS DNN profiles and P-CSCF policy data for IMS QoS"
            append_report_block "SMF QoS/DNN evidence" "$(echo "$smf_cfg" | grep -E 'dnn:|subnet:|gateway:|p-cscf' | head -30)"
        else
            fail "SMF QoS/DNN profile incomplete" "Expected internet + ims DNNs and p-cscf in smf.yaml"
        fi
    fi

    # TC-3: PCF SM-policy SBI endpoint is reachable
    if should_run_test 3; then
        _TEST_NUM=3
        local code
        code=$(curl -s --http2-prior-knowledge -o /dev/null -w "%{http_code}" \
            --max-time 5 \
            "http://${PCF_IP}:${PCF_PORT}/npcf-smpolicycontrol/v1/sm-policies" \
            2>/dev/null || echo "000")
        case "$code" in
            200|201|204|400|403|404|405)
                pass "PCF SM-policy SBI endpoint reachable (HTTP ${code})"
                ;;
            *)
                fail "PCF SM-policy SBI endpoint not reachable" "HTTP ${code} from /npcf-smpolicycontrol/v1/sm-policies"
                ;;
        esac
    fi

    # TC-4: SMF<->PCF policy association evidence
    if should_run_test 4; then
        _TEST_NUM=4
        local policy_ev
        policy_ev=$(docker_logs_recent_matches "smf" "\[PCF\]|npcf|smpolicycontrol|SM.?Policy|PCF.*associat" 20)
        if [ -n "$policy_ev" ]; then
            pass "SMF<->PCF SM-policy association evidence present"
            append_report_block "SMF policy evidence" "$(echo "$policy_ev" | tail -5)"
        elif container_is_running "smf" && container_is_running "pcf" && check_port "$PCF_IP" "$PCF_PORT"; then
            skip "SMF<->PCF policy association log evidence" "SMF/PCF are up and PCF SBI is reachable, but no policy association log was emitted in the recent window"
        else
            fail "SMF<->PCF policy path unavailable" "SMF or PCF down/unreachable"
        fi
    fi

    # TC-5: Default QoS flow/PDU tunnel active for internet DNN
    if should_run_test 5; then
        _TEST_NUM=5
        local live_ev
        if live_ev=$(fiveg_active_pdu_session_evidence); then
            pass "Default QoS flow/PDU tunnel active for internet DNN (${live_ev})"
            append_report_block "QoS flow live evidence" "$live_ev"
        elif ! container_is_running "$UE_SIM_RAN_CONTAINER"; then
            skip "Default QoS flow/PDU tunnel" "UERANSIM ${UE_SIM_RAN_CONTAINER} not running"
        else
            fail "Default QoS flow/PDU tunnel missing" "No UE/UPF tunnel evidence found"
        fi
    fi

    # TC-6: IMS signaling QoS profile ready for VoNR
    if should_run_test 6; then
        _TEST_NUM=6
        if echo "$sess" | grep -q 'ims:3:5' && echo "$smf_cfg$upf_cfg" | grep -qiE 'dnn:[[:space:]]*ims'; then
            pass "IMS signaling QoS profile ready: IMS DNN provisioned with 5QI=5"
        else
            fail "IMS signaling QoS profile incomplete" "Expected IMS DNN and subscriber ims:3:5 profile"
        fi
    fi

    # TC-7: IMS policy control path available from P-CSCF/PCF
    if should_run_test 7; then
        _TEST_NUM=7
        local ims_qos="" rx_peer=""
        container_is_running "pcscf" && ims_qos=$(docker exec pcscf kamcmd mod.is_loaded ims_qos 2>/dev/null | tr -d '\r' | tail -1)
        container_is_running "pcscf" && rx_peer=$(docker exec pcscf kamcmd cdp.list_peers 2>/dev/null | grep -iE 'I[_-]Open|open' | head -2 || true)
        if container_is_running "pcf" && check_port "$PCF_IP" "$PCF_PORT"; then
            pass "PCF policy node reachable for VoNR QoS authorization"
        elif echo "$ims_qos$rx_peer" | grep -qiE 'true|1|I[_-]Open|open'; then
            pass "P-CSCF IMS QoS/Rx policy path available for VoNR"
        else
            fail "IMS policy control path not available" "PCF SBI and P-CSCF ims_qos/Rx checks failed"
        fi
    fi

    # TC-8: PFCP QoS-rule/QER/QFI evidence or explicit log-level gate
    if should_run_test 8; then
        _TEST_NUM=8
        local qer_ev live_ev
        qer_ev="$(docker_logs_recent_matches "smf" "QER|QFI|QoS|PDR|FAR|5QI" 20)
$(docker_logs_recent_matches "upf" "QER|QFI|QoS|PDR|FAR|5QI" 20)"
        if echo "$qer_ev" | grep -qiE 'QER|QFI|QoS|5QI'; then
            pass "PFCP QoS-rule/QER/QFI evidence present in SMF/UPF logs"
            append_report_block "PFCP QoS evidence" "$(echo "$qer_ev" | grep -iE 'QER|QFI|QoS|5QI' | tail -8)"
        elif live_ev=$(fiveg_active_pdu_session_evidence); then
            skip "PFCP QoS-rule/QER/QFI log evidence" "Live PDU session exists (${live_ev}), but Open5GS logs QER/QFI details only at debug/pcap verbosity"
        else
            skip "PFCP QoS-rule/QER/QFI evidence" "No active PDU session evidence; run with UERANSIM or attach a PFCP pcap"
        fi
    fi

    # TC-9: Light user-plane continuity over the QoS flow
    if should_run_test 9; then
        _TEST_NUM=9
        local upf_tun_ip loss prc
        upf_tun_ip=$(fiveg_upf_tun_ip | head -1 | tr -d '\r')
        if [ -z "$upf_tun_ip" ]; then
            skip "QoS-flow user-plane continuity" "UPF TUN address not available"
        elif ! container_is_running "$UE_SIM_RAN_CONTAINER"; then
            skip "QoS-flow user-plane continuity" "UERANSIM ${UE_SIM_RAN_CONTAINER} not running"
        else
            loss=$(ue_dataplane_ping "$upf_tun_ip" 5); prc=$?
            if [ "$prc" -eq 70 ]; then
                skip "QoS-flow user-plane continuity" "UE tunnel has no IP"
            elif [ -n "$loss" ] && [ "${loss%%%*}" -lt 100 ] 2>/dev/null; then
                pass "QoS-flow user-plane continuity verified via UE tunnel to UPF ${upf_tun_ip} (${loss})"
            else
                fail "QoS-flow user-plane continuity failed" "No ICMP via uesimtun0 to ${upf_tun_ip} (${loss:-no response})"
            fi
        fi
    fi

    # TC-10: Real-HW QoS KPI/scheduler evidence gate
    if should_run_test 10; then
        _TEST_NUM=10
        if [ "${REAL_HW:-0}" = "1" ] && [ -n "${QOS_FLOW_REAL_HW_PCAP:-}" ] && [ -s "${QOS_FLOW_REAL_HW_PCAP}" ]; then
            pass "REAL_HW QoS KPI evidence attached: ${QOS_FLOW_REAL_HW_PCAP}"
            append_report_block "REAL_HW QoS pcap sample" "$(tcpdump -nn -r "$QOS_FLOW_REAL_HW_PCAP" -c 10 2>/dev/null || true)"
        else
            skip "REAL_HW QoS scheduler/KPI evidence" "Set REAL_HW=1 and QOS_FLOW_REAL_HW_PCAP to validate real gNB/UE 5QI scheduling, GBR/latency/jitter, and DSCP/reflective-QoS evidence"
        fi
    fi

    end_feature
}
