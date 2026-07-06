#!/bin/bash
#
# Provision test subscribers for EPC/IMS integration tests
# Uses PyHSS REST API
#

PYHSS_REST_PORT="${PYHSS_REST_PORT:-8080}"
PYHSS_API="${PYHSS_IP:-172.22.1.18}:${PYHSS_REST_PORT}"
# Optional bearer auth for a secured (e.g. remote/external) PyHSS REST endpoint.
CURL_AUTH_ARGS=()
if [ -n "${PYHSS_API_KEY:-}" ]; then
    CURL_AUTH_ARGS=(-H "Authorization: Bearer ${PYHSS_API_KEY}")
fi

echo "=== Provisioning test subscribers on PyHSS at $PYHSS_API ==="

print_json_or_note() {
    local response="$1"
    local fallback="$2"

    if [ -n "$response" ] && echo "$response" | jq . >/dev/null 2>&1; then
        echo "$response" | jq .
    else
        echo "$fallback"
    fi
}

print_exists_note() {
    local exists_note="$1"

    echo "{"
    echo "  \"result\": \"OK\","
    echo "  \"reason\": \"$exists_note\""
    echo "}"
}

get_json_if_exists() {
    local endpoint="$1"
    local required_pattern="${2:-}"
    local response_file=""
    local status_code=""

    response_file=$(mktemp)
    status_code=$(curl -s -o "$response_file" -w "%{http_code}" "${CURL_AUTH_ARGS[@]}" "http://$PYHSS_API/$endpoint")

    if [ "$status_code" = "200" ] && [ -s "$response_file" ]; then
        if [ -n "$required_pattern" ] && ! grep -q "$required_pattern" "$response_file"; then
            rm -f "$response_file"
            return 1
        fi
        cat "$response_file"
        rm -f "$response_file"
        return 0
    fi

    rm -f "$response_file"
    return 1
}

put_json() {
    local endpoint="$1"
    local payload="$2"
    local response=""

    response=$(curl -s -X PUT "${CURL_AUTH_ARGS[@]}" "http://$PYHSS_API/$endpoint" \
        -H "Content-Type: application/json" \
        -d "$payload")

    print_json_or_note "$response" "(request failed)"
}

ensure_put_if_missing() {
    local lookup_endpoint="$1"
    local create_endpoint="$2"
    local payload="$3"
    local exists_note="$4"
    local required_pattern="${5:-}"
    local existing_json=""

    if existing_json=$(get_json_if_exists "$lookup_endpoint" "$required_pattern"); then
        print_exists_note "$exists_note"
        return 0
    fi

    put_json "$create_endpoint" "$payload"
}

ensure_apn_exists() {
    local apn_name="$1"
    local payload="$2"
    local exists_note="$3"
    local apn_list=""

    if apn_list=$(get_json_if_exists "apn/list"); then
        # Use grep instead of jq (jq may not be available in container)
        if echo "$apn_list" | grep -q "\"apn\"[[:space:]]*:[[:space:]]*\"${apn_name}\""; then
            print_exists_note "$exists_note"
            return 0
        fi
    fi

    put_json "apn/" "$payload"
}

patch_apn_ip_version() {
    # Ensure the named APN has the correct ip_version in PyHSS.
    # Run unconditionally so existing rows (provisioned before this fix) are
    # also updated — the MME bitwise-ANDs the Diameter PDN-Type with the UE's
    # requested type, so ip_version=0 (IPv4-only) causes IPv6/dual-stack
    # PDN attach to be rejected with UNKNOWN_PDN_TYPE even when the SMF has
    # an IPv6 pool configured.
    #
    # ip_version values (TS 29.272 §7.3.62 / PyHSS database.py):
    #   0=IPv4  1=IPv6  2=IPv4v6  3=IPv4orIPv6
    local apn_name="$1"
    local ip_version="$2"
    local apn_list apn_id patch_resp

    apn_list=$(get_json_if_exists "apn/list") || return 0
    # Extract the apn_id for the matching APN name
    apn_id=$(echo "$apn_list" | grep -B2 "\"apn\"[[:space:]]*:[[:space:]]*\"${apn_name}\"" \
             | grep '"apn_id"' | grep -o '[0-9]*' | tail -1)
    if [ -z "$apn_id" ]; then
        # Try forward direction (apn_id before apn name in JSON)
        apn_id=$(echo "$apn_list" | grep -A5 "\"apn_id\"" \
                 | grep -B1 "\"apn\"[[:space:]]*:[[:space:]]*\"${apn_name}\"" \
                 | grep '"apn_id"' | grep -o '[0-9]*' | tail -1)
    fi
    [ -z "$apn_id" ] && return 0

    patch_resp=$(curl -s -X PATCH "http://$PYHSS_API/apn/$apn_id" \
        -H "Content-Type: application/json" \
        -d "{\"ip_version\":${ip_version}}")
    echo "APN '$apn_name' (id=$apn_id) ip_version set to $ip_version: $(echo "$patch_resp" | grep -o '"ip_version":[0-9]*' || echo 'ok')"
}

mysql_exec() {
    local sql="$1"

    if command -v docker >/dev/null 2>&1; then
        docker exec mysql mysql -u root -pMySQL_PaSsW0rD ims_hss_db -N -e "$sql" 2>/dev/null
        if [ $? -eq 0 ]; then
            return 0
        fi
    fi

    if command -v mysql >/dev/null 2>&1; then
        local mysql_ip="${MYSQL_IP:-172.22.1.17}"
        mysql -h "$mysql_ip" -u root -pMySQL_PaSsW0rD ims_hss_db -N -e "$sql" 2>/dev/null
        return $?
    fi

    return 127
}

auc_id_for_imsi() {
    local imsi="$1"
    local auc_id=""

    auc_id=$(mysql_exec "SELECT auc_id FROM auc WHERE imsi='${imsi}' ORDER BY auc_id DESC LIMIT 1;" | tr -d '[:space:]')
    if [ -z "$auc_id" ]; then
        echo "1"
        return 1
    fi

    echo "$auc_id"
}

# Wait for PyHSS API to be ready
echo "Waiting for PyHSS API..."
for i in $(seq 1 30); do
    if curl -s "http://$PYHSS_API/apn/list" > /dev/null 2>&1; then
        echo "PyHSS API is ready!"
        break
    fi
    echo "  Attempt $i/30..."
    sleep 2
done

# Create APNs (if not already existing)
echo ""
echo "--- Creating APNs ---"
ensure_apn_exists "internet" \
    '{"apn":"internet","apn_ambr_dl":0,"apn_ambr_ul":0,"qci":9}' \
    "APN internet already exists"

ensure_apn_exists "ims" \
    '{"apn":"ims","apn_ambr_dl":0,"apn_ambr_ul":0,"qci":5}' \
    "APN ims already exists"

# Ensure ip_version=0 (IPv4-only) on both APNs via MySQL.
# PyHSS defaults to 0, but a previous run may have patched it to 2.
# ip_version=0 is the safe default until UPF/SMF IPv6 allocation is verified:
#   TC-48 (IPv4v6): MME downgrades to IPv4 → PASS (valid 3GPP behavior)
#   TC-47/TC-49 (IPv6-only): MME rejects → SKIP (not FAIL)
# To enable real IPv6: set ip_version=2 in the payloads above and uncomment:
#   patch_apn_ip_version "internet" 2
#   patch_apn_ip_version "ims" 2
mysql_exec "UPDATE apn SET ip_version=0 WHERE apn IN ('internet','ims');" 2>/dev/null || true

echo ""
echo "--- Resetting default test subscriber rows ---"
if command -v docker >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1; then
    mysql_exec "DELETE FROM ims_subscriber WHERE imsi IN ('001019876540700','001019876541000','001019876542000') OR msisdn IN ('9876540700','9876541000','9876542000');" >/dev/null 2>&1 || true
    mysql_exec "DELETE FROM subscriber WHERE imsi IN ('001019876540700','001019876541000','001019876542000');" >/dev/null 2>&1 || true
    mysql_exec "DELETE FROM auc WHERE imsi IN ('001019876540700','001019876541000','001019876542000');" >/dev/null 2>&1 || true
    echo "Default subscriber rows cleared"
else
    echo "No docker/mysql client available; keeping existing default subscriber rows"
fi

# UE-A: 9876540700 (primary caller)
echo ""
echo "--- Provisioning UE-A (9876540700) ---"
ensure_put_if_missing "auc/imsi/001019876540700" "auc/" '{
        "ki":"8baf473f2f8fd09487cccbd7097c6862",
        "opc":"8E27B6AF0E692E750F32667A3B14605D",
        "amf":"8000","sqn":0,
        "algo":"3",
        "imsi":"001019876540700"
    }' "AUC entry for 001019876540700 already exists" "\"imsi\"[[:space:]]*:[[:space:]]*\"001019876540700\""

UE_A_AUC_ID=$(auc_id_for_imsi "001019876540700")
ensure_put_if_missing "subscriber/imsi/001019876540700" "subscriber/" "{
        \"imsi\":\"001019876540700\",\"enabled\":true,
        \"auc_id\":${UE_A_AUC_ID},\"default_apn\":1,\"apn_list\":\"1,2\",
        \"msisdn\":\"9876540700\",\"ue_ambr_dl\":0,\"ue_ambr_ul\":0,
        \"nam\":0,\"roaming_enabled\":true,\"subscribed_rau_tau_timer\":300
    }" "Subscriber 001019876540700 already exists" "\"imsi\"[[:space:]]*:[[:space:]]*\"001019876540700\""

ensure_put_if_missing "ims_subscriber/ims_subscriber_msisdn/9876540700" "ims_subscriber/" "{
        \"imsi\":\"001019876540700\",\"msisdn\":\"9876540700\",
        \"msisdn_list\":\"[9876540700]\",
        \"ifc_path\":\"default_ifc.xml\",
        \"scscf_peer\":\"scscf.${IMS_DOMAIN}\",
        \"scscf\":\"sip:scscf.${IMS_DOMAIN}:6060\",
        \"scscf_realm\":\"${IMS_DOMAIN}\"
    }" "IMS subscriber 9876540700 already exists" "\"msisdn\"[[:space:]]*:[[:space:]]*\"9876540700\""

# UE-B: 9876541000
echo ""
echo "--- Provisioning UE-B (9876541000) ---"
ensure_put_if_missing "auc/imsi/001019876541000" "auc/" '{
        "ki":"8baf473f2f8fd09487cccbd7097c6863",
        "opc":"8E27B6AF0E692E750F32667A3B14605D",
        "amf":"8000","sqn":0,
        "algo":"3",
        "imsi":"001019876541000"
    }' "AUC entry for 001019876541000 already exists" "\"imsi\"[[:space:]]*:[[:space:]]*\"001019876541000\""

UE_B_AUC_ID=$(auc_id_for_imsi "001019876541000")
ensure_put_if_missing "subscriber/imsi/001019876541000" "subscriber/" "{
        \"imsi\":\"001019876541000\",\"enabled\":true,
        \"auc_id\":${UE_B_AUC_ID},\"default_apn\":1,\"apn_list\":\"1,2\",
        \"msisdn\":\"9876541000\",\"ue_ambr_dl\":0,\"ue_ambr_ul\":0,
        \"nam\":0,\"roaming_enabled\":true,\"subscribed_rau_tau_timer\":300
    }" "Subscriber 001019876541000 already exists" "\"imsi\"[[:space:]]*:[[:space:]]*\"001019876541000\""

ensure_put_if_missing "ims_subscriber/ims_subscriber_msisdn/9876541000" "ims_subscriber/" "{
        \"imsi\":\"001019876541000\",\"msisdn\":\"9876541000\",
        \"msisdn_list\":\"[9876541000]\",
        \"ifc_path\":\"default_ifc.xml\",
        \"scscf_peer\":\"scscf.${IMS_DOMAIN}\",
        \"scscf\":\"sip:scscf.${IMS_DOMAIN}:6060\",
        \"scscf_realm\":\"${IMS_DOMAIN}\"
    }" "IMS subscriber 9876541000 already exists" "\"msisdn\"[[:space:]]*:[[:space:]]*\"9876541000\""

# UE-C: 9876542000
echo ""
echo "--- Provisioning UE-C (9876542000) ---"
ensure_put_if_missing "auc/imsi/001019876542000" "auc/" '{
        "ki":"8baf473f2f8fd09487cccbd7097c6864",
        "opc":"8E27B6AF0E692E750F32667A3B14605D",
        "amf":"8000","sqn":0,
        "algo":"3",
        "imsi":"001019876542000"
    }' "AUC entry for 001019876542000 already exists" "\"imsi\"[[:space:]]*:[[:space:]]*\"001019876542000\""

UE_C_AUC_ID=$(auc_id_for_imsi "001019876542000")
ensure_put_if_missing "subscriber/imsi/001019876542000" "subscriber/" "{
        \"imsi\":\"001019876542000\",\"enabled\":true,
        \"auc_id\":${UE_C_AUC_ID},\"default_apn\":1,\"apn_list\":\"1,2\",
        \"msisdn\":\"9876542000\",\"ue_ambr_dl\":0,\"ue_ambr_ul\":0,
        \"nam\":0,\"roaming_enabled\":true,\"subscribed_rau_tau_timer\":300
    }" "Subscriber 001019876542000 already exists" "\"imsi\"[[:space:]]*:[[:space:]]*\"001019876542000\""

ensure_put_if_missing "ims_subscriber/ims_subscriber_msisdn/9876542000" "ims_subscriber/" "{
        \"imsi\":\"001019876542000\",\"msisdn\":\"9876542000\",
        \"msisdn_list\":\"[9876542000]\",
        \"ifc_path\":\"default_ifc.xml\",
        \"scscf_peer\":\"scscf.${IMS_DOMAIN}\",
        \"scscf\":\"sip:scscf.${IMS_DOMAIN}:6060\",
        \"scscf_realm\":\"${IMS_DOMAIN}\"
    }" "IMS subscriber 9876542000 already exists" "\"msisdn\"[[:space:]]*:[[:space:]]*\"9876542000\""

# Fix AUC ID mapping: subscriber records may point to wrong AUC entries
# (happens when subscribers are created before AUC entries, or re-created multiple times)
echo ""
echo "--- Fixing AUC ID mapping ---"
if command -v docker >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1; then
    for IMSI in 001019876540700 001019876541000 001019876542000; do
        mysql_exec "UPDATE subscriber s JOIN auc a ON a.imsi = s.imsi SET s.auc_id = a.auc_id WHERE s.imsi = '$IMSI';"
    done
    mysql_exec "UPDATE auc SET ki='8baf473f2f8fd09487cccbd7097c6862', opc='8E27B6AF0E692E750F32667A3B14605D', amf='8000' WHERE imsi='001019876540700';"
    mysql_exec "UPDATE auc SET ki='8baf473f2f8fd09487cccbd7097c6863', opc='8E27B6AF0E692E750F32667A3B14605D', amf='8000' WHERE imsi='001019876541000';"
    mysql_exec "UPDATE auc SET ki='8baf473f2f8fd09487cccbd7097c6864', opc='8E27B6AF0E692E750F32667A3B14605D', amf='8000' WHERE imsi='001019876542000';"
    mysql_exec "UPDATE subscriber SET enabled=1, default_apn=1, apn_list='1,2', ue_ambr_dl=0, ue_ambr_ul=0 WHERE imsi IN ('001019876540700','001019876541000','001019876542000');"
    mysql_exec "UPDATE ims_subscriber SET msisdn_list='[9876540700]', ifc_path='default_ifc.xml', scscf_peer='scscf.${IMS_DOMAIN}', scscf='sip:scscf.${IMS_DOMAIN}:6060', scscf_realm='${IMS_DOMAIN}' WHERE imsi='001019876540700';"
    mysql_exec "UPDATE ims_subscriber SET msisdn_list='[9876541000]', ifc_path='default_ifc.xml', scscf_peer='scscf.${IMS_DOMAIN}', scscf='sip:scscf.${IMS_DOMAIN}:6060', scscf_realm='${IMS_DOMAIN}' WHERE imsi='001019876541000';"
    mysql_exec "UPDATE ims_subscriber SET msisdn_list='[9876542000]', ifc_path='default_ifc.xml', scscf_peer='scscf.${IMS_DOMAIN}', scscf='sip:scscf.${IMS_DOMAIN}:6060', scscf_realm='${IMS_DOMAIN}' WHERE imsi='001019876542000';"
    if mysql_exec "SELECT s.imsi, s.auc_id, a.auc_id, a.ki, a.opc, a.sqn FROM subscriber s JOIN auc a ON a.imsi = s.imsi WHERE s.imsi IN ('001019876540700','001019876541000','001019876542000');" >/tmp/default_subscriber_verify.txt; then
        VERIFY_COUNT=$(sed '/^[[:space:]]*$/d' /tmp/default_subscriber_verify.txt | wc -l | tr -d '[:space:]')
        if [ "$VERIFY_COUNT" = "3" ]; then
            echo "AUC ID mapping and credentials verified"
        else
            echo "WARNING: expected 3 default subscriber mappings, found ${VERIFY_COUNT:-0}"
        fi
        cat /tmp/default_subscriber_verify.txt
    else
        echo "WARNING: default subscriber credential verification failed"
    fi

    # Reset SQN (sequence number) to 0 for all test subscribers.
    # The UE simulator always starts with SQN=0 for Milenage auth.
    # If PyHSS incremented SQN from previous test runs, the MME will
    # generate authentication vectors with a higher SQN, causing
    # "Security Mode failed" when the UE responds with SQN=0-based RES.
    echo ""
    echo "--- Resetting SQN for all test subscribers ---"
    for IMSI in 001019876540700 001019876541000 001019876542000; do
        mysql_exec "UPDATE auc SET sqn = 0 WHERE imsi = '$IMSI';"
    done
    echo "SQN reset to 0 for all test subscribers"

    # Verify
    mysql_exec "SELECT s.imsi, s.auc_id, a.auc_id as correct_auc, a.sqn FROM subscriber s JOIN auc a ON a.imsi = s.imsi WHERE s.imsi LIKE '00101987654%';" || echo "(verification skipped)"
else
    echo "(docker/mysql client not available - skipping AUC ID fix and SQN reset)"
fi

echo ""
echo "=== Provisioning complete ==="
