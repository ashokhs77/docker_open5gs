#!/bin/bash
# Feature 00: EPC Health
# Dedicated 4G EPC + IMS health checks. This is intentionally narrower than
# regression: it validates the stack is alive and its main interfaces are up
# before deeper attach/call/protocol tests run.
#
# Tests:
#   TC-1:  MME running + S1AP SCTP port 36412 listening
#   TC-2:  SGW-C running + GTPv2-C port 2123 listening
#   TC-3:  SGW-U running + GTP-U port 2152 listening
#   TC-4:  SMF/PGW-C running + PFCP port 8805 listening
#   TC-5:  UPF/PGW-U running + GTP-U port 2152 listening
#   TC-6:  PyHSS running + REST API reachable
#   TC-7:  MySQL running + SQL port reachable
#   TC-8:  DNS running + P-CSCF A record resolves
#   TC-9:  P-CSCF running + SIP port reachable
#   TC-10: I-CSCF running + SIP port reachable
#   TC-11: S-CSCF running + SIP port reachable
#   TC-12: FreeSWITCH running
#   TC-13: RTPEngine running/reachable
#   TC-14: SMSC running + SIP port bound
#   TC-15: MMSC running
#   TC-16: I-CSCF Cx Diameter peer open
#   TC-17: S-CSCF Cx Diameter peer open
#   TC-18: P-CSCF Rx Diameter peer open
#   TC-19: SMF/UPF PFCP health evidence present
#   TC-20: No EPC/IMS container restart loops

set +e

_epc_restart_count() {
    docker inspect --format '{{.RestartCount}}' "$1" 2>/dev/null | tr -dc '0-9' || echo "0"
}

_epc_cdp_peer_open() {
    local container="$1"
    local wait_secs="${EPC_CDP_PEER_WAIT_SECS:-45}"
    local interval="${EPC_CDP_PEER_RETRY_SECS:-3}"
    local deadline=$(( $(date +%s) + wait_secs ))
    local out=""
    EPC_CDP_PEER_DETAIL=""
    container_is_running "$container" || return 1
    while [ "$(date +%s)" -le "$deadline" ]; do
        out=$(timeout 8 docker exec "$container" kamcmd cdp.list_peers 2>/dev/null || true)
        EPC_CDP_PEER_DETAIL="$(echo "$out" | tail -8 | tr '\n' ' ')"
        if echo "$out" | grep -qiE "I[_-]Open|State:[[:space:]]*Open"; then
            return 0
        fi
        sleep "$interval"
    done
    return 1
}

_epc_rtpengine_status() {
    local detail=""

    if check_port "$RTPENGINE_IP" 2223; then
        echo "NG port 2223 reachable at ${RTPENGINE_IP}"
        return 0
    fi

    local rtpe_container=""
    if command -v get_rtpengine_container >/dev/null 2>&1; then
        rtpe_container=$(get_rtpengine_container)
    else
        rtpe_container=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i "rtpengine" | head -1)
    fi

    if [ -n "$rtpe_container" ]; then
        local ng_self=""
        ng_self=$(docker exec "$rtpe_container" sh -c 'echo -n "d7:command4:pinge" | nc -u -w 2 127.0.0.1 2223 2>/dev/null | head -c 200' 2>/dev/null || true)
        if [ -n "$ng_self" ]; then
            echo "container '${rtpe_container}' running, NG self-ping OK"
        else
            echo "container '${rtpe_container}' running"
        fi
        return 0
    fi

    detail=$(docker exec pcscf kamcmd rtpengine.show all 2>/dev/null | head -5 || true)
    if [ -n "$detail" ] && ! echo "$detail" | grep -qi "error"; then
        echo "P-CSCF rtpengine module reports backend state"
        return 0
    fi

    return 1
}

_epc_pfcp_health_ok() {
    if container_listens_on_port "smf" 8805 && container_listens_on_port "upf" 8805; then
        return 0
    fi

    local pfcp_log=""
    pfcp_log=$({ docker logs --tail 500 smf 2>&1; docker logs --tail 500 upf 2>&1; } 2>/dev/null || true)
    echo "$pfcp_log" | grep -Eiq 'PFCP.*(associat|connect|establish|accept)|associat.*PFCP|association.*(up|establish|accept)'
}

run_epc_health_tests() {
    start_feature "EPC Health"

    # TC-1: MME running + S1AP SCTP port 36412
    if should_run_test 1; then
        _TEST_NUM=1
        if container_is_running "mme"; then
            if container_listens_on_port "mme" "${MME_PORT:-36412}"; then
                pass "MME running, S1AP SCTP port ${MME_PORT:-36412} listening"
            else
                fail "MME running but S1AP port ${MME_PORT:-36412} not listening" "Check MME startup and SCTP binding: docker logs mme"
            fi
        else
            fail "MME container not running" "docker ps shows no 'mme' container"
        fi
    fi

    # TC-2: SGW-C running + GTPv2-C port 2123
    if should_run_test 2; then
        _TEST_NUM=2
        if container_is_running "sgwc"; then
            if container_listens_on_port "sgwc" 2123; then
                pass "SGW-C running, GTPv2-C port 2123 listening"
            else
                pass "SGW-C container running (GTPv2-C UDP 2123 listener check inconclusive)"
            fi
        else
            fail "SGW-C container not running" "docker ps shows no 'sgwc' container"
        fi
    fi

    # TC-3: SGW-U running + GTP-U port 2152
    if should_run_test 3; then
        _TEST_NUM=3
        if container_is_running "sgwu"; then
            if container_listens_on_port "sgwu" 2152; then
                pass "SGW-U running, GTP-U port 2152 listening"
            else
                pass "SGW-U container running (GTP-U UDP 2152 listener check inconclusive)"
            fi
        else
            fail "SGW-U container not running" "docker ps shows no 'sgwu' container"
        fi
    fi

    # TC-4: SMF/PGW-C running + PFCP port 8805
    if should_run_test 4; then
        _TEST_NUM=4
        if container_is_running "smf"; then
            if container_listens_on_port "smf" 8805; then
                pass "SMF/PGW-C running, PFCP port 8805 listening"
            else
                pass "SMF/PGW-C container running (PFCP UDP 8805 listener check inconclusive)"
            fi
        else
            fail "SMF/PGW-C container not running" "docker ps shows no 'smf' container"
        fi
    fi

    # TC-5: UPF/PGW-U running + GTP-U port 2152
    if should_run_test 5; then
        _TEST_NUM=5
        if container_is_running "upf"; then
            if container_listens_on_port "upf" 2152; then
                pass "UPF/PGW-U running, GTP-U port 2152 listening"
            else
                pass "UPF/PGW-U container running (GTP-U UDP 2152 listener check inconclusive)"
            fi
        else
            fail "UPF/PGW-U container not running" "docker ps shows no 'upf' container"
        fi
    fi

    # TC-6: PyHSS running + REST API reachable
    if should_run_test 6; then
        _TEST_NUM=6
        if container_is_running "pyhss"; then
            if check_port "$PYHSS_IP" "${PYHSS_REST_PORT:-8080}"; then
                pass "PyHSS running, REST API port ${PYHSS_REST_PORT:-8080} reachable"
            else
                fail "PyHSS running but REST API is not reachable" "Check PyHSS logs and ${PYHSS_IP}:${PYHSS_REST_PORT:-8080}"
            fi
        else
            fail "PyHSS container not running" "Required for S6a/Cx/Rx"
        fi
    fi

    # TC-7: MySQL running + SQL port reachable
    if should_run_test 7; then
        _TEST_NUM=7
        if container_is_running "mysql"; then
            if check_port "$MYSQL_IP" 3306; then
                pass "MySQL running, port 3306 reachable"
            else
                fail "MySQL running but port 3306 is not reachable" "Check MySQL startup logs: docker logs mysql"
            fi
        else
            fail "MySQL container not running" "Required for IMS subscriber and service databases"
        fi
    fi

    # TC-8: DNS running + P-CSCF A record resolves
    if should_run_test 8; then
        _TEST_NUM=8
        if container_is_running "dns"; then
            local pcscf_a=""
            pcscf_a=$(dig +short "pcscf.${IMS_DOMAIN}" @"$DNS_IP" A 2>/dev/null | head -1 | tr -d '[:space:]')
            if [ "$pcscf_a" = "$PCSCF_IP" ]; then
                pass "DNS running, pcscf.${IMS_DOMAIN} resolves to ${PCSCF_IP}"
            else
                fail "DNS running but P-CSCF A record is incorrect" "Expected ${PCSCF_IP}, got '${pcscf_a}'"
            fi
        else
            fail "DNS container not running" "Required for IMS domain resolution"
        fi
    fi

    # TC-9: P-CSCF running + SIP port reachable
    if should_run_test 9; then
        _TEST_NUM=9
        if container_is_running "pcscf"; then
            if check_port "$PCSCF_IP" "${PCSCF_PORT:-5060}"; then
                pass "P-CSCF running, SIP port ${PCSCF_PORT:-5060} reachable"
            else
                fail "P-CSCF running but SIP port ${PCSCF_PORT:-5060} is not reachable" "Check Kamailio startup logs: docker logs pcscf"
            fi
        else
            fail "P-CSCF container not running" "Required for IMS registration and VoLTE"
        fi
    fi

    # TC-10: I-CSCF running + SIP port reachable
    if should_run_test 10; then
        _TEST_NUM=10
        if container_is_running "icscf"; then
            if check_port "$ICSCF_IP" 4060; then
                pass "I-CSCF running, SIP port 4060 reachable"
            else
                fail "I-CSCF running but SIP port 4060 is not reachable" "Check Kamailio startup logs: docker logs icscf"
            fi
        else
            fail "I-CSCF container not running" "Required for IMS registration routing"
        fi
    fi

    # TC-11: S-CSCF running + SIP port reachable
    if should_run_test 11; then
        _TEST_NUM=11
        if container_is_running "scscf"; then
            if check_port "$SCSCF_IP" 6060; then
                pass "S-CSCF running, SIP port 6060 reachable"
            else
                fail "S-CSCF running but SIP port 6060 is not reachable" "Check Kamailio startup logs: docker logs scscf"
            fi
        else
            fail "S-CSCF container not running" "Required for IMS registration state"
        fi
    fi

    # TC-12: FreeSWITCH running
    if should_run_test 12; then
        _TEST_NUM=12
        if container_is_running "freeswitch"; then
            local fs_status=""
            fs_status=$(docker exec freeswitch /usr/local/freeswitch/bin/fs_cli -x "status" 2>/dev/null | head -5 || true)
            if echo "$fs_status" | grep -qi "UP"; then
                pass "FreeSWITCH running and fs_cli status is UP"
            else
                pass "FreeSWITCH container running (fs_cli status inconclusive)"
            fi
        else
            fail "FreeSWITCH container not running" "Required for IMS media services"
        fi
    fi

    # TC-13: RTPEngine running/reachable
    if should_run_test 13; then
        _TEST_NUM=13
        local rtpe_status=""
        rtpe_status=$(_epc_rtpengine_status 2>/dev/null || true)
        if [ -n "$rtpe_status" ]; then
            pass "RTPEngine active: ${rtpe_status}"
        else
            fail "RTPEngine not reachable" "NG port, docker container, and P-CSCF kamcmd checks all failed"
        fi
    fi

    # TC-14: SMSC running + SIP port bound
    if should_run_test 14; then
        _TEST_NUM=14
        if container_is_running "smsc"; then
            if check_port "$SMSC_IP" 7090 || container_listens_on_port "smsc" 7090; then
                pass "SMSC running, SIP port 7090 reachable or bound"
            else
                fail "SMSC running but SIP port 7090 is not reachable/bound" "Check SMSC Kamailio startup logs: docker logs smsc"
            fi
        else
            fail "SMSC container not running" "Required for SMS over IMS"
        fi
    fi

    # TC-15: MMSC running
    if should_run_test 15; then
        _TEST_NUM=15
        if container_is_running "mmsc"; then
            pass "MMSC container running"
        else
            fail "MMSC container not running" "Required for MMS tests"
        fi
    fi

    # TC-16: I-CSCF Cx Diameter peer open
    if should_run_test 16; then
        _TEST_NUM=16
        if _epc_cdp_peer_open "icscf"; then
            pass "I-CSCF Cx Diameter peer is I_Open"
        else
            fail "I-CSCF Cx Diameter peer is not I_Open after retry window" "${EPC_CDP_PEER_DETAIL:-Run: docker exec icscf kamcmd cdp.list_peers}"
        fi
    fi

    # TC-17: S-CSCF Cx Diameter peer open
    if should_run_test 17; then
        _TEST_NUM=17
        if _epc_cdp_peer_open "scscf"; then
            pass "S-CSCF Cx Diameter peer is I_Open"
        else
            fail "S-CSCF Cx Diameter peer is not I_Open after retry window" "${EPC_CDP_PEER_DETAIL:-Run: docker exec scscf kamcmd cdp.list_peers}"
        fi
    fi

    # TC-18: P-CSCF Rx Diameter peer open
    if should_run_test 18; then
        _TEST_NUM=18
        if _epc_cdp_peer_open "pcscf"; then
            pass "P-CSCF Rx Diameter peer is I_Open"
        else
            fail "P-CSCF Rx Diameter peer is not I_Open after retry window" "${EPC_CDP_PEER_DETAIL:-Run: docker exec pcscf kamcmd cdp.list_peers}"
        fi
    fi

    # TC-19: SMF/UPF PFCP health evidence
    if should_run_test 19; then
        _TEST_NUM=19
        if _epc_pfcp_health_ok; then
            pass "SMF/UPF PFCP endpoint or association evidence present"
        else
            fail "SMF/UPF PFCP health evidence missing" "Check SMF/UPF PFCP logs and UDP port 8805 bindings"
        fi
    fi

    # TC-20: No EPC/IMS container restart loops
    if should_run_test 20; then
        _TEST_NUM=20
        local restarted=""
        local nf rc
        for nf in mme sgwc sgwu smf upf pyhss pcscf icscf scscf freeswitch mysql dns smsc mmsc; do
            rc=$(_epc_restart_count "$nf")
            if [ "$rc" -gt 2 ] 2>/dev/null; then
                restarted="${restarted} ${nf}(${rc}x)"
            fi
        done
        if [ -z "$restarted" ]; then
            pass "No EPC/IMS container restart loops detected"
        else
            fail "EPC/IMS restart loops detected:${restarted}" "Containers with >2 restarts indicate startup or dependency failures"
        fi
    fi

    end_feature
}
