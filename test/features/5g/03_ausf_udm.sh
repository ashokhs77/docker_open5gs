#!/bin/bash
# Feature 03: AUSF / UDM Authentication
# Validates the 5G authentication and subscriber data plane:
# MongoDB (5G NF subscriber store), UDR/UDM HTTP APIs, AUSF auth service,
# and subscriber provisioning/retrieval.
#
# Tests:
#   TC-1: MongoDB port 27017 reachable
#   TC-2: UDR SBI port 7777 reachable
#   TC-3: UDM SBI port 7777 reachable
#   TC-4: AUSF SBI port 7777 reachable
#   TC-5: MongoDB 'open5gs' database exists
#   TC-6: UDM nudm-uecm API accessible
#   TC-7: AUSF nausf-auth API accessible
#   TC-8: WebUI port 9999 reachable (subscriber management)

set +e

run_ausf_udm_tests() {
    start_feature "AUSF/UDM Auth"

    # TC-1: MongoDB port reachable
    if should_run_test 1; then
        _TEST_NUM=1
        if check_port "$MONGO_IP" 27017; then
            pass "MongoDB port 27017 reachable at ${MONGO_IP}"
        else
            fail "MongoDB port 27017 not reachable" \
                 "5G NF subscriber data is stored in MongoDB; UDR/UDM will fail without it"
        fi
    fi

    # TC-2: UDR SBI port reachable
    if should_run_test 2; then
        _TEST_NUM=2
        if check_port "$UDR_IP" "$UDR_PORT"; then
            pass "UDR SBI port ${UDR_PORT} reachable at ${UDR_IP}"
        else
            fail "UDR SBI port ${UDR_PORT} not reachable" \
                 "UDR provides subscriber data to UDM; check UDR container and MongoDB connectivity"
        fi
    fi

    # TC-3: UDM SBI port reachable
    if should_run_test 3; then
        _TEST_NUM=3
        if check_port "$UDM_IP" "$UDM_PORT"; then
            pass "UDM SBI port ${UDM_PORT} reachable at ${UDM_IP}"
        else
            fail "UDM SBI port ${UDM_PORT} not reachable" \
                 "UDM handles authentication data for AMF; check UDM container and NRF registration"
        fi
    fi

    # TC-4: AUSF SBI port reachable
    if should_run_test 4; then
        _TEST_NUM=4
        if check_port "$AUSF_IP" "$AUSF_PORT"; then
            pass "AUSF SBI port ${AUSF_PORT} reachable at ${AUSF_IP}"
        else
            fail "AUSF SBI port ${AUSF_PORT} not reachable" \
                 "AUSF performs 5G AKA; UE registration will fail without it"
        fi
    fi

    # TC-5: MongoDB 'open5gs' database exists
    if should_run_test 5; then
        _TEST_NUM=5
        if container_is_running "mongo"; then
            local db_list
            db_list=$(mongo_eval "" \
                'db.adminCommand({listDatabases:1}).databases.map(d=>d.name).join(",")' \
                || echo "")
            if echo "$db_list" | grep -q "open5gs"; then
                pass "MongoDB 'open5gs' database exists"
            else
                fail "MongoDB 'open5gs' database not found" \
                     "Databases found: ${db_list}. WebUI or open5gs init may not have run yet."
            fi
        else
            skip "MongoDB 'open5gs' database check" "MongoDB container not running"
        fi
    fi

    # TC-6: UDM nudm-uecm API accessible
    if should_run_test 6; then
        _TEST_NUM=6
        local http_code
        http_code=$(curl -s --http2-prior-knowledge -o /dev/null -w "%{http_code}" \
            --max-time 5 \
            "http://${UDM_IP}:${UDM_PORT}/nudm-uecm/v1/imsi-001011234567895/registrations" \
            2>/dev/null || echo "000")
        # 404 means API is up but subscriber not found — that's fine for health check
        if [ "$http_code" = "200" ] || [ "$http_code" = "404" ] || [ "$http_code" = "204" ] || [ "$http_code" = "403" ]; then
            pass "UDM nudm-uecm API accessible (HTTP ${http_code})"
        else
            fail "UDM nudm-uecm API returned HTTP ${http_code}" \
                 "Expected 200/404 for API health; check UDM startup and NRF registration"
        fi
    fi

    # TC-7: AUSF nausf-auth API accessible
    if should_run_test 7; then
        _TEST_NUM=7
        local http_code
        http_code=$(curl -s --http2-prior-knowledge -o /dev/null -w "%{http_code}" \
            --max-time 5 \
            "http://${AUSF_IP}:${AUSF_PORT}/nausf-auth/v1/ue-authentications" \
            2>/dev/null || echo "000")
        # 405 Method Not Allowed on GET is fine — it means the API is running
        if [ "$http_code" = "200" ] || [ "$http_code" = "404" ] || [ "$http_code" = "405" ] || [ "$http_code" = "415" ]; then
            pass "AUSF nausf-auth API accessible (HTTP ${http_code})"
        else
            fail "AUSF nausf-auth API returned HTTP ${http_code}" \
                 "Expected 200/404/405 for API health; check AUSF startup"
        fi
    fi

    # TC-8: WebUI port 9999 reachable (subscriber management)
    if should_run_test 8; then
        _TEST_NUM=8
        if container_is_running "webui"; then
            if check_port "${WEBUI_IP:-172.22.1.26}" 9999; then
                pass "WebUI port 9999 reachable (subscriber management available)"
            else
                fail "WebUI container running but port 9999 not reachable" \
                     "Check WebUI container logs and MongoDB connectivity"
            fi
        else
            skip "WebUI port check" "WebUI container not running (not required for core 5G operation)"
        fi
    fi

    end_feature
}
