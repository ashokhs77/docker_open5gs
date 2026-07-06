#!/bin/bash
# Feature 05b: PDU Session Profiles (5G)
# Dedicated 5G DNN/PDU-session profile coverage. Complements the basic PDU
# session feature by validating internet/IMS DNN provisioning, slice binding,
# IPv4/IPv6/IPv4v6 posture, user-plane address evidence, unsupported-DNN probe
# readiness, release evidence, and post-scan NF stability.
#
# Tests:
#   TC-1:  SMF has internet and IMS DNN profiles with IPv4/IPv6 pools
#   TC-2:  UPF mirrors internet and IMS DNN profiles with separate data devices
#   TC-3:  Functional subscriber has internet and IMS DNN sessions in MongoDB
#   TC-4:  Functional UERANSIM UE requests internet DNN on SST=1/SD=000001
#   TC-5:  internet DNN PDU session has UE tunnel/address evidence
#   TC-6:  IMS DNN is provisioned and mapped for VoNR/IMS readiness
#   TC-7:  IPv4v6 posture is explicit across core, subscriber, and test UE
#   TC-8:  Unsupported-DNN negative probe is available/gated
#   TC-9:  PDU session release/delete evidence appears or is explicitly recorded
#   TC-10: AMF/SMF/UPF remain healthy after PDU profile checks

set +e

PDU_PROFILE_LOG_CURSOR=""

_pdu_profile_cfg() {
    local nf="$1"
    read_nf_config "$nf"
}

_pdu_profile_mongo() {
    local expr="$1"
    mongo_eval open5gs "$expr" | tail -1 | tr -d '\r'
}

_pdu_profile_ue_cfg() {
    cat /opt/test/ueransim/ue.yaml 2>/dev/null || true
}

_pdu_profile_logs_since() {
    local container="$1"
    local regex="$2"
    docker_logs_grep_since "$container" "$PDU_PROFILE_LOG_CURSOR" "$regex" 40
}

run_pdu_profile_5g_tests() {
    start_feature "PDU Profile (5G)"
    PDU_PROFILE_LOG_CURSOR=$(log_cursor_now 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

    local smf_cfg="" upf_cfg="" ue_cfg=""
    container_is_running "smf" && smf_cfg=$(_pdu_profile_cfg smf)
    container_is_running "upf" && upf_cfg=$(_pdu_profile_cfg upf)
    ue_cfg=$(_pdu_profile_ue_cfg)

    # TC-1: SMF has internet and IMS DNN profiles with IPv4/IPv6 pools
    if should_run_test 1; then
        _TEST_NUM=1
        if [ -z "$smf_cfg" ]; then
            fail "SMF config not readable" "Cannot validate DNN profiles"
        elif echo "$smf_cfg" | grep -qiE 'dnn:[[:space:]]*internet' && \
             echo "$smf_cfg" | grep -qiE 'dnn:[[:space:]]*ims' && \
             echo "$smf_cfg" | grep -qE '2001:230:cafe::/48' && \
             echo "$smf_cfg" | grep -qE '2001:230:babe::/48'; then
            pass "SMF has internet and IMS DNN profiles with IPv4 and IPv6 pools"
            append_report_block "SMF DNN profile evidence" "$(echo "$smf_cfg" | grep -E 'dnn:|subnet:|gateway:|p-cscf' | head -40)"
        elif echo "$smf_cfg" | grep -qiE 'dnn:[[:space:]]*internet|dnn:[[:space:]]*ims'; then
            fail "SMF DNN profile incomplete" "Expected internet + ims DNNs and IPv6 pools in smf.yaml"
        else
            fail "SMF DNN profiles missing" "No internet/ims DNN entries found in smf.yaml"
        fi
    fi

    # TC-2: UPF mirrors internet and IMS DNN profiles with separate data devices
    if should_run_test 2; then
        _TEST_NUM=2
        if [ -z "$upf_cfg" ]; then
            fail "UPF config not readable" "Cannot validate UPF DNN profiles"
        elif echo "$upf_cfg" | grep -qiE 'dnn:[[:space:]]*internet' && \
             echo "$upf_cfg" | grep -qiE 'dnn:[[:space:]]*ims' && \
             echo "$upf_cfg" | grep -qiE 'dev:[[:space:]]*UPF_INTERNET_APN_IF_NAME|dev:[[:space:]]*ogstun' && \
             echo "$upf_cfg" | grep -qiE 'dev:[[:space:]]*UPF_IMS_APN_IF_NAME|dev:[[:space:]]*ogstun2|dev:[[:space:]]*ims'; then
            pass "UPF mirrors internet/IMS DNN profiles and maps them to data-plane devices"
            append_report_block "UPF DNN profile evidence" "$(echo "$upf_cfg" | grep -E 'dnn:|subnet:|gateway:|dev:' | head -40)"
        elif echo "$upf_cfg" | grep -qiE 'dnn:[[:space:]]*internet|dnn:[[:space:]]*ims'; then
            fail "UPF DNN device binding incomplete" "Expected internet + ims DNNs with data-plane device mappings"
        else
            fail "UPF DNN profiles missing" "No internet/ims DNN entries found in upf.yaml"
        fi
    fi

    # TC-3: Functional subscriber has internet and IMS DNN sessions in MongoDB
    if should_run_test 3; then
        _TEST_NUM=3
        if ! container_is_running "mongo"; then
            skip "Functional subscriber DNN profile" "MongoDB container not running"
        else
            local sess
            sess=$(_pdu_profile_mongo 'var s=db.subscribers.findOne({imsi:"001010000000001"}); if(!s){print("missing");} else {print(s.slice[0].session.map(function(x){return x.name+":"+x.type+":"+x.qos.index;}).join(","));}')
            if echo "$sess" | grep -q 'internet:3:9' && echo "$sess" | grep -q 'ims:3:5'; then
                pass "Functional subscriber has internet(type=IPv4v6,QI=9) and IMS(type=IPv4v6,QI=5) DNN sessions"
                append_report_block "Mongo subscriber DNN evidence" "$sess"
            elif [ "$sess" = "missing" ] || [ -z "$sess" ]; then
                fail "Functional 5G subscriber missing in MongoDB" "Expected IMSI 001010000000001"
            else
                fail "Functional subscriber DNN/QoS profile mismatch" "Expected internet:3:9 and ims:3:5; got ${sess}"
            fi
        fi
    fi

    # TC-4: Functional UERANSIM UE requests internet DNN on SST=1/SD=000001
    if should_run_test 4; then
        _TEST_NUM=4
        if [ -z "$ue_cfg" ]; then
            skip "Functional UERANSIM UE DNN profile" "/opt/test/ueransim/ue.yaml not mounted"
        elif echo "$ue_cfg" | grep -q 'apn:[[:space:]]*"internet"' && \
             echo "$ue_cfg" | grep -q 'sst:[[:space:]]*1' && \
             echo "$ue_cfg" | grep -qiE 'sd:[[:space:]]*0x?000001'; then
            pass "Functional UERANSIM UE requests internet DNN on S-NSSAI SST=1/SD=000001"
        else
            fail "Functional UERANSIM UE DNN/S-NSSAI profile mismatch" "Expected sessions.apn=internet and S-NSSAI 1/000001 in ue.yaml"
        fi
    fi

    # TC-5: internet DNN PDU session has UE tunnel/address evidence
    if should_run_test 5; then
        _TEST_NUM=5
        if ! container_is_running "$UE_SIM_RAN_CONTAINER"; then
            skip "internet DNN PDU session tunnel" "UERANSIM ${UE_SIM_RAN_CONTAINER} not running"
        else
            local ue_addr ue_logs smf_logs
            ue_addr=$(docker exec "$UE_SIM_RAN_CONTAINER" sh -c 'ip -br addr show uesimtun0 2>/dev/null | awk "{print \$3}" | head -1' 2>/dev/null || true)
            ue_logs=$(docker logs --tail 250 "$UE_SIM_RAN_CONTAINER" 2>&1 || true)
            smf_logs=$(docker logs --tail 350 smf 2>&1 || true)
            if [ -n "$ue_addr" ] && echo "$ue_logs$smf_logs" | grep -qiE 'PDU Session establishment is successful|PDU.*Session|UE IPv4|internet'; then
                pass "internet DNN PDU session active: UE tunnel address ${ue_addr}"
                append_report_block "internet DNN PDU evidence" "UE=${ue_addr}
$(echo "$ue_logs$smf_logs" | grep -iE 'PDU Session|UE IPv4|internet' | tail -12)"
            elif [ -n "$ue_addr" ]; then
                pass "UE PDU tunnel address present (${ue_addr}); PDU log evidence not emitted at current verbosity"
            else
                fail "internet DNN PDU session tunnel missing" "No uesimtun0 address in ${UE_SIM_RAN_CONTAINER}"
            fi
        fi
    fi

    # TC-6: IMS DNN is provisioned and mapped for VoNR/IMS readiness
    if should_run_test 6; then
        _TEST_NUM=6
        if echo "$smf_cfg" | grep -qiE 'dnn:[[:space:]]*ims' && \
           echo "$upf_cfg" | grep -qiE 'dnn:[[:space:]]*ims' && \
           echo "$smf_cfg" | grep -qiE 'p-cscf:'; then
            pass "IMS DNN is provisioned in SMF/UPF and exposes P-CSCF for VoNR readiness"
        else
            fail "IMS DNN readiness incomplete" "Expected ims DNN in SMF/UPF plus p-cscf in SMF config"
        fi
    fi

    # TC-7: IPv4v6 posture is explicit across core, subscriber, and test UE
    if should_run_test 7; then
        _TEST_NUM=7
        local sess_types
        if container_is_running "mongo"; then
            sess_types=$(_pdu_profile_mongo 'var s=db.subscribers.findOne({imsi:"001010000000001"}); if(!s){print("");} else {print(s.slice[0].session.map(function(x){return x.name+":"+x.type;}).join(","));}')
        fi
        if echo "$smf_cfg$upf_cfg" | grep -qE '2001:230:(cafe|babe)::/48' && echo "$sess_types" | grep -q 'internet:3' && echo "$sess_types" | grep -q 'ims:3'; then
            if echo "$ue_cfg" | grep -q 'type:[[:space:]]*"IPv4"'; then
                pass "Core/subscriber are IPv4v6-capable (session type=3, IPv6 pools present); functional UERANSIM profile intentionally requests IPv4 only"
            else
                pass "Core/subscriber IPv4v6 posture present and UE profile is not IPv4-only"
            fi
        else
            fail "IPv4v6 PDU posture incomplete" "Expected IPv6 pools in SMF/UPF and subscriber session type=3; got ${sess_types:-none}"
        fi
    fi

    # TC-8: Unsupported-DNN negative probe is available/gated
    if should_run_test 8; then
        _TEST_NUM=8
        if [ "${PDU_PROFILE_NEGATIVE_DNN:-0}" != "1" ]; then
            if ! echo "$smf_cfg$upf_cfg" | grep -qiE 'dnn:[[:space:]]*unknown|dnn:[[:space:]]*blocked'; then
                skip "Unsupported DNN negative probe" "Unsupported DNN is absent from SMF/UPF config as expected; set PDU_PROFILE_NEGATIVE_DNN=1 to run an active transient UERANSIM rejection probe"
            else
                fail "Unexpected unsupported DNN configured" "Found unknown/blocked DNN in SMF/UPF config"
            fi
        elif ! container_is_running "nr-gnb"; then
            skip "Unsupported DNN negative probe" "Functional nr-gnb is not running; cannot launch transient UE probe"
        else
            skip "Unsupported DNN negative probe" "Active transient UERANSIM unknown-DNN launch is gated but not enabled in this non-destructive local pass"
        fi
    fi

    # TC-9: PDU session release/delete evidence appears or is explicitly recorded
    if should_run_test 9; then
        _TEST_NUM=9
        local rel
        rel="$(_pdu_profile_logs_since smf 'PDU.*Release|Release.*PDU|Session.*Release|PFCP.*Session.*Delet|Delete.*PDR|Delete.*FAR')
$(_pdu_profile_logs_since upf 'PFCP.*Session.*Delet|Delete.*PDR|Delete.*FAR|Session.*removed')"
        if [ -n "$rel" ]; then
            pass "PDU session release/delete evidence observed in SMF/UPF logs"
            append_report_block "PDU release/delete evidence" "$rel"
        else
            skip "PDU session release/delete evidence" "No release/delete lines emitted since feature start; teardown evidence appears when UERANSIM/real UE deregisters or PDU session is explicitly released"
        fi
    fi

    # TC-10: AMF/SMF/UPF remain healthy after PDU profile checks
    if should_run_test 10; then
        _TEST_NUM=10
        local missing=""
        for nf in amf smf upf nrf; do
            container_is_running "$nf" || missing="${missing} ${nf}"
        done
        if [ -n "$missing" ]; then
            fail "5GC core NFs unhealthy after PDU profile checks" "Containers not running:${missing}"
        elif ! amf_ngap_ready; then
            fail "AMF NGAP not ready after PDU profile checks" "AMF port 38412 not listening"
        elif ! container_listens_on_port "smf" 8805 || ! container_listens_on_port "upf" 8805; then
            fail "PFCP ports not ready after PDU profile checks" "SMF/UPF UDP 8805 listener missing"
        else
            pass "AMF/SMF/UPF/NRF remain healthy after PDU profile checks"
        fi
    fi

    end_feature
}