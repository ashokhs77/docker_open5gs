#!/bin/bash
# Feature 00d: PyHSS API Negative Input
# Dedicated 4G PyHSS REST API input-validation coverage. Negative inputs must
# be rejected cleanly with 4xx-style behavior, must not expose real subscriber
# data, must not create residue rows, and must not crash/restart PyHSS.
#
# Tests:
#   TC-1:  PyHSS REST API reachable before negative-input battery
#   TC-2:  Unknown subscriber lookup returns clean not-found/no-data
#   TC-3:  Unknown AUC lookup returns clean not-found/no-data
#   TC-4:  Malformed IMSI path is rejected without 5xx
#   TC-5:  Malformed JSON AUC PUT is rejected without 5xx
#   TC-6:  Invalid AUC field lengths are rejected without 5xx
#   TC-7:  Invalid subscriber APN/AUC references are rejected without 5xx
#   TC-8:  Invalid IMS subscriber identity/route is rejected without 5xx
#   TC-9:  Unsupported API method/path is rejected without 5xx
#   TC-10: PyHSS remains alive after negative-input battery and leaves no residue

set +e

_api_neg_seed="${PYHSS_API_NEG_SEED:-$(date +%s)}"
case "$_api_neg_seed" in
    ''|*[!0-9]*) _api_neg_seed="1" ;;
esac
_api_neg_base=$(( (10#${_api_neg_seed} + $$) % 1000000 ))
PYHSS_API_NEG_MSISDN="${PYHSS_API_NEG_MSISDN:-9898$(printf '%06d' "$_api_neg_base")}"
PYHSS_API_NEG_MSISDN="$(echo "$PYHSS_API_NEG_MSISDN" | tr -d '[:space:]')"
PYHSS_API_NEG_IMSI="${PYHSS_API_NEG_IMSI:-00101${PYHSS_API_NEG_MSISDN}}"
PYHSS_API_NEG_BAD_IMSI="${PYHSS_API_NEG_BAD_IMSI:-00101$(printf '%010d' $(( (_api_neg_base + 17) % 10000000000 )))}"
PYHSS_API_NEG_URL="http://${PYHSS_IP}:${PYHSS_REST_PORT:-8080}"
PYHSS_API_NEG_RESTARTS_BEFORE=""

_api_neg_code() {
    echo "$1" | tail -1 | tr -d '[:space:]'
}

_api_neg_body() {
    echo "$1" | sed '$d'
}

_api_neg_request() {
    local method="$1"
    local url="$2"
    local body="${3-}"
    local content_type="${4:-application/json}"
    local timeout_s="${PYHSS_API_NEG_TIMEOUT:-5}"
    local args=(-s -w "\n%{http_code}" --max-time "$timeout_s" -X "$method")

    if [ -n "$content_type" ]; then
        args+=(-H "Content-Type: ${content_type}")
    fi
    if [ -n "$PYHSS_API_KEY" ]; then
        args+=(-H "Authorization: Bearer ${PYHSS_API_KEY}")
    fi
    if [ "$#" -ge 3 ] && [ -n "$body" ]; then
        args+=(-d "$body")
    fi

    curl "${args[@]}" "$url" 2>/dev/null || echo "000"
}

_api_neg_mysql() {
    local sql="$1"
    docker exec mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD:-MySQL_PaSsW0rD}" ims_hss_db -N -B -e "$sql" 2>/dev/null
}

_api_neg_mysql_scalar() {
    _api_neg_mysql "$1" | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//'
}

_api_neg_cleanup() {
    local imsis="'${PYHSS_API_NEG_IMSI}','${PYHSS_API_NEG_BAD_IMSI}','not-an-imsi'"
    _api_neg_mysql "DELETE FROM ims_subscriber WHERE imsi IN (${imsis}) OR msisdn='${PYHSS_API_NEG_MSISDN}';" >/dev/null 2>&1 || true
    _api_neg_mysql "DELETE FROM subscriber WHERE imsi IN (${imsis}) OR msisdn='${PYHSS_API_NEG_MSISDN}';" >/dev/null 2>&1 || true
    _api_neg_mysql "DELETE FROM auc WHERE imsi IN (${imsis});" >/dev/null 2>&1 || true
}

_api_neg_residue_count() {
    _api_neg_mysql_scalar "SELECT (SELECT COUNT(*) FROM auc WHERE imsi IN ('${PYHSS_API_NEG_IMSI}','${PYHSS_API_NEG_BAD_IMSI}','not-an-imsi')) + (SELECT COUNT(*) FROM subscriber WHERE imsi IN ('${PYHSS_API_NEG_IMSI}','${PYHSS_API_NEG_BAD_IMSI}','not-an-imsi') OR msisdn='${PYHSS_API_NEG_MSISDN}') + (SELECT COUNT(*) FROM ims_subscriber WHERE imsi IN ('${PYHSS_API_NEG_IMSI}','${PYHSS_API_NEG_BAD_IMSI}','not-an-imsi') OR msisdn='${PYHSS_API_NEG_MSISDN}');"
}

_api_neg_restart_count() {
    docker inspect --format '{{.RestartCount}}' pyhss 2>/dev/null | tr -dc '0-9'
}

_api_neg_expect_reject() {
    local code="$1"
    local label="$2"
    local detail="$3"

    case "$code" in
        4*) pass "${label}: rejected cleanly with HTTP ${code}" ;;
        5*) fail "${label}: returned HTTP ${code} for negative input" "Expected 4xx-style rejection, not server-side error. ${detail}" ;;
        2*|3*) fail "${label}: accepted invalid input with HTTP ${code}" "Expected rejection. ${detail}" ;;
        000|"") fail "${label}: no HTTP response" "PyHSS did not respond to negative-input probe. ${detail}" ;;
        *) pass "${label}: returned HTTP ${code} without 2xx/5xx" ;;
    esac
}

_api_neg_body_has_record() {
    local body="$1"
    local imsi="$2"
    echo "$body" | grep -qE '"(subscriber_id|auc_id)"[[:space:]]*:[[:space:]]*[1-9][0-9]*' && \
        echo "$body" | grep -qE "\"imsi\"[[:space:]]*:[[:space:]]*\"${imsi}\""
}

run_pyhss_api_tests() {
    start_feature "PyHSS API Negative"
    _api_neg_cleanup
    PYHSS_API_NEG_RESTARTS_BEFORE=$(_api_neg_restart_count)

    # TC-1: PyHSS REST API reachable before negative-input battery
    if should_run_test 1; then
        _TEST_NUM=1
        local resp code
        resp=$(_api_neg_request GET "${PYHSS_API_NEG_URL}/apn/list" "" "")
        code=$(_api_neg_code "$resp")
        if [ "$code" = "200" ]; then
            pass "PyHSS REST API reachable before negative-input battery"
        elif [ "$code" = "000" ] || [ -z "$code" ]; then
            fail "PyHSS REST API not reachable" "GET /apn/list produced no HTTP response"
        else
            fail "PyHSS REST API returned HTTP ${code}" "Expected HTTP 200 from /apn/list before negative-input battery"
        fi
    fi

    # TC-2: Unknown subscriber lookup returns clean not-found/no-data
    if should_run_test 2; then
        _TEST_NUM=2
        local resp code body
        resp=$(_api_neg_request GET "${PYHSS_API_NEG_URL}/subscriber/imsi/${PYHSS_API_NEG_IMSI}" "" "")
        code=$(_api_neg_code "$resp")
        body=$(_api_neg_body "$resp")
        if [ "$code" = "404" ]; then
            pass "Unknown subscriber lookup returns HTTP 404"
        elif [[ "$code" =~ ^5[0-9][0-9]$ ]]; then
            fail "Unknown subscriber lookup returned HTTP ${code}" "GET /subscriber/imsi/${PYHSS_API_NEG_IMSI} must not crash"
        elif [ "$code" = "200" ]; then
            if _api_neg_body_has_record "$body" "$PYHSS_API_NEG_IMSI"; then
                fail "Unknown subscriber lookup exposed a real-looking record" "Response body contains subscriber data for ${PYHSS_API_NEG_IMSI}"
            else
                pass "Unknown subscriber lookup returned HTTP 200 with no subscriber data exposed"
            fi
        elif [[ "$code" =~ ^4[0-9][0-9]$ ]]; then
            pass "Unknown subscriber lookup rejected cleanly with HTTP ${code}"
        else
            fail "Unknown subscriber lookup produced HTTP ${code:-none}" "Expected 4xx/no-data behavior"
        fi
    fi

    # TC-3: Unknown AUC lookup returns clean not-found/no-data
    if should_run_test 3; then
        _TEST_NUM=3
        local resp code body
        resp=$(_api_neg_request GET "${PYHSS_API_NEG_URL}/auc/imsi/${PYHSS_API_NEG_IMSI}" "" "")
        code=$(_api_neg_code "$resp")
        body=$(_api_neg_body "$resp")
        if [ "$code" = "404" ]; then
            pass "Unknown AUC lookup returns HTTP 404"
        elif [[ "$code" =~ ^5[0-9][0-9]$ ]]; then
            fail "Unknown AUC lookup returned HTTP ${code}" "GET /auc/imsi/${PYHSS_API_NEG_IMSI} must not crash"
        elif [ "$code" = "200" ]; then
            if _api_neg_body_has_record "$body" "$PYHSS_API_NEG_IMSI"; then
                fail "Unknown AUC lookup exposed a real-looking record" "Response body contains AUC data for ${PYHSS_API_NEG_IMSI}"
            else
                pass "Unknown AUC lookup returned HTTP 200 with no AUC data exposed"
            fi
        elif [[ "$code" =~ ^4[0-9][0-9]$ ]]; then
            pass "Unknown AUC lookup rejected cleanly with HTTP ${code}"
        else
            fail "Unknown AUC lookup produced HTTP ${code:-none}" "Expected 4xx/no-data behavior"
        fi
    fi

    # TC-4: Malformed IMSI path is rejected without 5xx
    if should_run_test 4; then
        _TEST_NUM=4
        local resp code
        resp=$(_api_neg_request GET "${PYHSS_API_NEG_URL}/subscriber/imsi/not-an-imsi" "" "")
        code=$(_api_neg_code "$resp")
        _api_neg_expect_reject "$code" "Malformed IMSI path" "GET /subscriber/imsi/not-an-imsi"
    fi

    # TC-5: Malformed JSON AUC PUT is rejected without 5xx
    if should_run_test 5; then
        _TEST_NUM=5
        local resp code
        resp=$(_api_neg_request PUT "${PYHSS_API_NEG_URL}/auc/" "{\"imsi\":\"${PYHSS_API_NEG_BAD_IMSI}\",\"ki\":\"short\"," "application/json")
        code=$(_api_neg_code "$resp")
        _api_neg_expect_reject "$code" "Malformed JSON AUC PUT" "PUT /auc/ with truncated JSON"
    fi

    # TC-6: Invalid AUC field lengths are rejected without 5xx
    if should_run_test 6; then
        _TEST_NUM=6
        local resp code
        resp=$(_api_neg_request PUT "${PYHSS_API_NEG_URL}/auc/" "{\"ki\":\"short\",\"opc\":\"bad\",\"amf\":\"8\",\"sqn\":0,\"imsi\":\"${PYHSS_API_NEG_BAD_IMSI}\",\"algo\":\"3\"}" "application/json")
        code=$(_api_neg_code "$resp")
        _api_neg_expect_reject "$code" "Invalid AUC field lengths" "PUT /auc/ with short Ki/OPc/AMF"
        _api_neg_cleanup
    fi

    # TC-7: Invalid subscriber APN/AUC references are rejected without 5xx
    if should_run_test 7; then
        _TEST_NUM=7
        local resp code
        resp=$(_api_neg_request PUT "${PYHSS_API_NEG_URL}/subscriber/" "{\"imsi\":\"${PYHSS_API_NEG_BAD_IMSI}\",\"enabled\":true,\"auc_id\":999999999,\"default_apn\":999999999,\"apn_list\":\"999999999\",\"msisdn\":\"${PYHSS_API_NEG_MSISDN}\",\"ue_ambr_dl\":0,\"ue_ambr_ul\":0,\"nam\":0,\"roaming_enabled\":true}" "application/json")
        code=$(_api_neg_code "$resp")
        _api_neg_expect_reject "$code" "Invalid subscriber APN/AUC references" "PUT /subscriber/ with nonexistent auc_id/default_apn/apn_list"
        _api_neg_cleanup
    fi

    # TC-8: Invalid IMS subscriber identity/route is rejected without 5xx
    if should_run_test 8; then
        _TEST_NUM=8
        local resp code
        resp=$(_api_neg_request PUT "${PYHSS_API_NEG_URL}/ims_subscriber/" "{\"imsi\":\"not-an-imsi\",\"msisdn\":\"${PYHSS_API_NEG_MSISDN}\",\"msisdn_list\":\"[]\",\"ifc_path\":\"missing.xml\",\"scscf_peer\":\"\",\"scscf\":\"not-a-sip-uri\",\"scscf_realm\":\"\"}" "application/json")
        code=$(_api_neg_code "$resp")
        _api_neg_expect_reject "$code" "Invalid IMS subscriber identity/route" "PUT /ims_subscriber/ with malformed identity and route fields"
        _api_neg_cleanup
    fi

    # TC-9: Unsupported API method/path is rejected without 5xx
    if should_run_test 9; then
        _TEST_NUM=9
        local resp code
        resp=$(_api_neg_request POST "${PYHSS_API_NEG_URL}/subscriber/list" "{}" "application/json")
        code=$(_api_neg_code "$resp")
        _api_neg_expect_reject "$code" "Unsupported subscriber-list POST" "POST /subscriber/list should be rejected"
    fi

    # TC-10: PyHSS remains alive after negative-input battery and leaves no residue
    if should_run_test 10; then
        _TEST_NUM=10
        local resp code restarts_after residue
        resp=$(_api_neg_request GET "${PYHSS_API_NEG_URL}/apn/list" "" "")
        code=$(_api_neg_code "$resp")
        restarts_after=$(_api_neg_restart_count)
        residue=$(_api_neg_residue_count)
        if [ "$code" != "200" ]; then
            fail "PyHSS API not healthy after negative-input battery" "GET /apn/list returned HTTP ${code}"
        elif [ -n "$PYHSS_API_NEG_RESTARTS_BEFORE" ] && [ -n "$restarts_after" ] && [ "$restarts_after" != "$PYHSS_API_NEG_RESTARTS_BEFORE" ]; then
            fail "PyHSS restarted during negative-input battery" "RestartCount before=${PYHSS_API_NEG_RESTARTS_BEFORE}, after=${restarts_after}"
        elif [ -n "$residue" ] && [ "$residue" != "0" ]; then
            _api_neg_cleanup
            fail "PyHSS negative-input battery left invalid DB residue" "Residue rows=${residue}; cleanup attempted"
        else
            pass "PyHSS alive after negative-input battery with no restart or invalid DB residue"
        fi
    fi

    _api_neg_cleanup
    end_feature
}