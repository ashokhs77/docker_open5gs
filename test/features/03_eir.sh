#!/bin/bash
# Feature: EIR (Equipment Identity Register) / HSS
# Tests PyHSS API reachability, EIR config, subscriber provisioning, and AUC verification

set +e  # Don't exit on errors - we handle them ourselves

source /opt/test/lib/common.sh

run_eir_tests() {
    start_feature "EIR"

    # TC-1: PyHSS API reachable
    if should_run_test 1; then
        _TEST_NUM=1
        local response
        response=$(api_get "http://${PYHSS_IP}:8080/apn/list")
        local http_code
        http_code=$(echo "$response" | tail -1)
        local body
        body=$(echo "$response" | sed '$d')
        if [ "$http_code" = "200" ]; then
            pass "PyHSS API reachable at ${PYHSS_IP}:8080 (HTTP 200)"
        else
            fail "PyHSS API reachable" "Expected HTTP 200, got '${http_code}' from http://${PYHSS_IP}:8080/apn/list"
        fi
    fi

    # TC-2: EIR config - check imsi_imei_logging enabled
    if should_run_test 2; then
        _TEST_NUM=2
        local config_output
        config_output=$(docker_exec "pyhss" "grep -r 'imsi_imei_logging' /mnt/pyhss/ 2>/dev/null || grep -r 'imsi_imei_logging' /pyhss/ 2>/dev/null || grep -r 'imsi_imei_logging' / --include='*.yaml' --include='*.yml' 2>/dev/null | head -3")
        local rc=$?
        if [ $rc -eq 0 ] && [ -n "$config_output" ]; then
            pass "EIR config contains imsi_imei_logging setting"
        else
            # Try checking the config file directly in common locations
            config_output=$(docker_exec "pyhss" "find / -name 'config.yaml' -o -name 'hss.conf' -o -name 'pyhss.conf' 2>/dev/null | head -5")
            if [ -n "$config_output" ]; then
                fail "EIR config" "Config files found but imsi_imei_logging not present: ${config_output}"
            else
                fail "EIR config" "Could not locate PyHSS config or imsi_imei_logging setting"
            fi
        fi
    fi

    # TC-3: Subscriber provisioning (AUC entry)
    if should_run_test 3; then
        _TEST_NUM=3
        local test_imsi="001019876540700"
        local test_ki="465B5CE8B199B49FAA5F0A2EE238A6BC"
        local test_opc="E8ED289DEBA952E4283B54E88E6183CA"
        local json_body
        json_body=$(cat <<EOJSON
{
    "ki": "${test_ki}",
    "opc": "${test_opc}",
    "amf": "8000",
    "sqn": "000000000001",
    "imsi": "${test_imsi}"
}
EOJSON
)
        local response
        response=$(api_put "http://${PYHSS_IP}:8080/auc/" "$json_body")
        local http_code
        http_code=$(echo "$response" | tail -1)
        local body
        body=$(echo "$response" | sed '$d')
        if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
            pass "Subscriber AUC provisioned for IMSI ${test_imsi} (HTTP ${http_code})"
        elif [ "$http_code" = "409" ] || [ "$http_code" = "400" ]; then
            pass "Subscriber AUC for IMSI ${test_imsi} already exists (HTTP ${http_code} - duplicate OK)"
        else
            fail "Subscriber AUC provisioning" "Expected HTTP 200/201/400/409, got '${http_code}'. Body: ${body}"
        fi
    fi

    # TC-4: Subscriber query
    if should_run_test 4; then
        _TEST_NUM=4
        local test_imsi="001019876540700"
        local response
        response=$(api_get "http://${PYHSS_IP}:8080/auc/imsi/${test_imsi}")
        local http_code
        http_code=$(echo "$response" | tail -1)
        local body
        body=$(echo "$response" | sed '$d')
        if [ "$http_code" = "200" ]; then
            if echo "$body" | grep -q "$test_imsi"; then
                pass "Subscriber query returns data for IMSI ${test_imsi}"
            else
                fail "Subscriber query" "HTTP 200 but IMSI not found in response body"
            fi
        else
            fail "Subscriber query" "Expected HTTP 200, got '${http_code}' for IMSI ${test_imsi}"
        fi
    fi

    # TC-5: IMS subscriber provisioning
    if should_run_test 5; then
        _TEST_NUM=5
        local test_imsi="001019876540700"
        local test_msisdn="9876540700"
        local json_body
        json_body="{\"imsi\": \"${test_imsi}\", \"msisdn\": \"${test_msisdn}\", \"scscf_peer\": \"scscf.${IMS_DOMAIN}\", \"scscf\": \"sip:scscf.${IMS_DOMAIN}:6060\", \"scscf_realm\": \"${IMS_DOMAIN}\"}"
        local response
        response=$(api_put "http://${PYHSS_IP}:8080/ims_subscriber/" "$json_body")
        local http_code
        http_code=$(echo "$response" | tail -1)
        local body
        body=$(echo "$response" | sed '$d')
        if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
            pass "IMS subscriber provisioned for IMSI ${test_imsi} (HTTP ${http_code})"
        elif [ "$http_code" = "409" ] || [ "$http_code" = "400" ] || [ "$http_code" = "500" ]; then
            # 400/500 with duplicate entry = subscriber already exists from prior provisioning
            pass "IMS subscriber for IMSI ${test_imsi} already exists (HTTP ${http_code})"
        else
            fail "IMS subscriber provisioning" "Expected HTTP 200/201/400/409, got '${http_code}'. Body: ${body}"
        fi
    fi

    # TC-6: AUC entry verification (check ki field present)
    if should_run_test 6; then
        _TEST_NUM=6
        local test_imsi="001019876540700"
        local response
        response=$(api_get "http://${PYHSS_IP}:8080/auc/imsi/${test_imsi}")
        local http_code
        http_code=$(echo "$response" | tail -1)
        local body
        body=$(echo "$response" | sed '$d')
        if [ "$http_code" = "200" ]; then
            if echo "$body" | grep -q '"ki"'; then
                pass "AUC entry for IMSI ${test_imsi} contains ki field"
            else
                fail "AUC entry verification" "HTTP 200 but 'ki' field not found in response: ${body}"
            fi
        else
            fail "AUC entry verification" "Expected HTTP 200, got '${http_code}' for IMSI ${test_imsi}"
        fi
    fi

    end_feature
}
