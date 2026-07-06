#!/bin/bash
# Feature 00b: HSS AUC Authentication
# Dedicated 4G authentication coverage for PyHSS/AUC, S6a AKA, NAS security,
# authentication rejection, SQN/AUTS resync, and IMS AKA registration.
#
# Tests:
#   TC-1:  PyHSS REST + S6a Diameter ports reachable
#   TC-2:  Dedicated auth subscribers provisioned via PyHSS API
#   TC-3:  AUC/subscriber MySQL mapping and credentials valid
#   TC-4:  Milenage vector derivation from provisioned AUC data
#   TC-5:  Positive EPC attach authenticates and negotiates NAS security
#   TC-6:  AUC SQN advances after a successful attach
#   TC-7:  Valid IMSI with wrong Ki is rejected
#   TC-8:  Unknown IMSI is rejected
#   TC-9:  SQN re-synchronisation via AUTS succeeds
#   TC-10: IMS AKA registration succeeds for the auth subscriber

set +e

_hss_seed="${HSS_AUTH_SEED:-$(date +%s)}"
case "$_hss_seed" in
    ''|*[!0-9]*) _hss_seed="1" ;;
esac
_hss_base=$(( (10#${_hss_seed} + $$) % 1000000 ))
_hss_base_b=$(( (_hss_base + 1) % 1000000 ))
_hss_base_unknown=$(( (_hss_base + 500000) % 1000000 ))

HSS_AUTH_MSISDN="${HSS_AUTH_MSISDN:-9876$(printf '%06d' "$_hss_base")}"
HSS_AUTH_NEG_MSISDN="${HSS_AUTH_NEG_MSISDN:-9876$(printf '%06d' "$_hss_base_b")}"
HSS_AUTH_UNKNOWN_MSISDN="${HSS_AUTH_UNKNOWN_MSISDN:-9877$(printf '%06d' "$_hss_base_unknown")}"
HSS_AUTH_IMSI="${HSS_AUTH_IMSI:-00101${HSS_AUTH_MSISDN}}"
HSS_AUTH_NEG_IMSI="${HSS_AUTH_NEG_IMSI:-00101${HSS_AUTH_NEG_MSISDN}}"
HSS_AUTH_UNKNOWN_IMSI="${HSS_AUTH_UNKNOWN_IMSI:-00101${HSS_AUTH_UNKNOWN_MSISDN}}"
HSS_AUTH_KI="${HSS_AUTH_KI:-1b1b1b1b2c2c2c2c3d3d3d3d4e4e4e4e}"
HSS_AUTH_NEG_KI="${HSS_AUTH_NEG_KI:-5a5a5a5a6b6b6b6b7c7c7c7c8d8d8d8d}"
HSS_AUTH_WRONG_KI="${HSS_AUTH_WRONG_KI:-ffffffffffffffffffffffffffffffff}"
HSS_AUTH_OPC="${HSS_AUTH_OPC:-8E27B6AF0E692E750F32667A3B14605D}"
HSS_AUTH_AMF="${HSS_AUTH_AMF:-8000}"
HSS_AUTH_PREPARED=false
HSS_AUTH_PREP_DETAIL=""

_hss_http_code() {
    echo "$1" | tail -1 | tr -d '[:space:]'
}

_hss_http_body() {
    echo "$1" | sed '$d'
}

_hss_mysql() {
    local sql="$1"
    docker exec mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD:-MySQL_PaSsW0rD}" ims_hss_db -N -B -e "$sql" 2>/dev/null
}

_hss_mysql_scalar() {
    _hss_mysql "$1" | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//'
}

_hss_json_get() {
    local json="$1"
    local key="$2"
    printf '%s' "$json" | "$PYTHON_BIN" -c "import sys,json; d=json.load(sys.stdin); v=d.get('$key',''); print('' if v is None else v)" 2>/dev/null || echo ""
}

_hss_ue_sim_import_ok() {
    "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import sys
sys.path.insert(0, '/opt/test')
from ue_sim.ue_simulator import UESimulator
from ue_sim.config import Config
from ue_sim.milenage import Milenage
PY
}

_hss_delete_auth_subscribers() {
    local imsi_list="'${HSS_AUTH_IMSI}','${HSS_AUTH_NEG_IMSI}'"
    local msisdn_list="'${HSS_AUTH_MSISDN}','${HSS_AUTH_NEG_MSISDN}'"
    _hss_mysql "DELETE FROM ims_subscriber WHERE imsi IN (${imsi_list}) OR msisdn IN (${msisdn_list});" >/dev/null 2>&1 || true
    _hss_mysql "DELETE FROM subscriber WHERE imsi IN (${imsi_list});" >/dev/null 2>&1 || true
    _hss_mysql "DELETE FROM auc WHERE imsi IN (${imsi_list});" >/dev/null 2>&1 || true
}

_hss_prepare_one_subscriber() {
    local imsi="$1"
    local msisdn="$2"
    local ki="$3"
    local resp code auc_id

    resp=$(api_put "http://${PYHSS_IP}:8080/auc/" \
        "{\"ki\":\"${ki}\",\"opc\":\"${HSS_AUTH_OPC}\",\"amf\":\"${HSS_AUTH_AMF}\",\"sqn\":0,\"imsi\":\"${imsi}\",\"algo\":\"3\"}")
    code=$(_hss_http_code "$resp")
    if [ "$code" != "200" ] && [ "$code" != "201" ] && [ "$code" != "400" ] && [ "$code" != "409" ]; then
        HSS_AUTH_PREP_DETAIL="${HSS_AUTH_PREP_DETAIL} AUC(${imsi}):HTTP${code}"
        return 1
    fi

    auc_id=$(_hss_mysql_scalar "SELECT auc_id FROM auc WHERE imsi='${imsi}' ORDER BY auc_id DESC LIMIT 1;")
    if [ -z "$auc_id" ]; then
        HSS_AUTH_PREP_DETAIL="${HSS_AUTH_PREP_DETAIL} AUC_ID(${imsi}):missing"
        return 1
    fi

    resp=$(api_put "http://${PYHSS_IP}:8080/subscriber/" \
        "{\"imsi\":\"${imsi}\",\"enabled\":true,\"auc_id\":${auc_id},\"default_apn\":1,\"apn_list\":\"1,2\",\"msisdn\":\"${msisdn}\",\"ue_ambr_dl\":0,\"ue_ambr_ul\":0,\"nam\":0,\"roaming_enabled\":true,\"subscribed_rau_tau_timer\":300}")
    code=$(_hss_http_code "$resp")
    if [ "$code" != "200" ] && [ "$code" != "201" ] && [ "$code" != "400" ] && [ "$code" != "409" ]; then
        HSS_AUTH_PREP_DETAIL="${HSS_AUTH_PREP_DETAIL} SUB(${imsi}):HTTP${code}"
        return 1
    fi

    resp=$(api_put "http://${PYHSS_IP}:8080/ims_subscriber/" \
        "{\"imsi\":\"${imsi}\",\"msisdn\":\"${msisdn}\",\"msisdn_list\":\"[${msisdn}]\",\"ifc_path\":\"default_ifc.xml\",\"scscf_peer\":\"scscf.${IMS_DOMAIN}\",\"scscf\":\"sip:scscf.${IMS_DOMAIN}:6060\",\"scscf_realm\":\"${IMS_DOMAIN}\"}")
    code=$(_hss_http_code "$resp")
    if [ "$code" != "200" ] && [ "$code" != "201" ] && [ "$code" != "400" ] && [ "$code" != "409" ] && [ "$code" != "500" ]; then
        HSS_AUTH_PREP_DETAIL="${HSS_AUTH_PREP_DETAIL} IMS(${imsi}):HTTP${code}"
        return 1
    fi

    _hss_mysql "UPDATE auc SET ki='${ki}', opc='${HSS_AUTH_OPC}', amf='${HSS_AUTH_AMF}', algo=3, sqn=0 WHERE imsi='${imsi}';" >/dev/null 2>&1 || true
    _hss_mysql "UPDATE subscriber s JOIN auc a ON a.imsi=s.imsi SET s.auc_id=a.auc_id, s.enabled=1, s.default_apn=1, s.apn_list='1,2', s.msisdn='${msisdn}', s.ue_ambr_dl=0, s.ue_ambr_ul=0 WHERE s.imsi='${imsi}';" >/dev/null 2>&1 || true
    _hss_mysql "UPDATE ims_subscriber SET imsi='${imsi}', msisdn='${msisdn}', msisdn_list='[${msisdn}]', ifc_path='default_ifc.xml', scscf_peer='scscf.${IMS_DOMAIN}', scscf='sip:scscf.${IMS_DOMAIN}:6060', scscf_realm='${IMS_DOMAIN}' WHERE imsi='${imsi}' OR msisdn='${msisdn}';" >/dev/null 2>&1 || true
    return 0
}

_hss_auth_subscriber_state() {
    local imsi="$1"
    _hss_mysql "SELECT COALESCE(a.auc_id,-1), COALESCE(s.auc_id,-2), COALESCE(a.ki,''), COALESCE(a.opc,''), COALESCE(a.algo,-1), COALESCE(a.sqn,-1), COALESCE(s.enabled,-1), COALESCE(s.apn_list,''), COALESCE(s.msisdn,'') FROM auc a JOIN subscriber s ON s.imsi=a.imsi WHERE a.imsi='${imsi}' LIMIT 1;"
}

_hss_verify_one_subscriber() {
    local imsi="$1"
    local msisdn="$2"
    local ki="$3"
    local state auc_id sub_auc_id row_ki row_opc row_algo row_sqn row_enabled row_apn row_msisdn
    state=$(_hss_auth_subscriber_state "$imsi")
    if [ -z "$state" ]; then
        HSS_AUTH_PREP_DETAIL="${HSS_AUTH_PREP_DETAIL} DB(${imsi}):missing"
        return 1
    fi
    IFS=$'\t' read -r auc_id sub_auc_id row_ki row_opc row_algo row_sqn row_enabled row_apn row_msisdn <<< "$state"
    if [ "$auc_id" = "$sub_auc_id" ] && \
       [ "$(echo "$row_ki" | tr '[:upper:]' '[:lower:]')" = "$(echo "$ki" | tr '[:upper:]' '[:lower:]')" ] && \
       [ "$(echo "$row_opc" | tr '[:upper:]' '[:lower:]')" = "$(echo "$HSS_AUTH_OPC" | tr '[:upper:]' '[:lower:]')" ] && \
       [ "$row_algo" = "3" ] && [ "$row_enabled" = "1" ] && \
       [ "$row_msisdn" = "$msisdn" ] && echo "$row_apn" | grep -q "1"; then
        return 0
    fi
    HSS_AUTH_PREP_DETAIL="${HSS_AUTH_PREP_DETAIL} DB(${imsi}):auc=${auc_id}/sub=${sub_auc_id},algo=${row_algo},enabled=${row_enabled},apn=${row_apn},msisdn=${row_msisdn}"
    return 1
}

_hss_prepare_auth_subscribers() {
    HSS_AUTH_PREP_DETAIL=""
    if ! container_is_running "pyhss" || ! check_port "$PYHSS_IP" "${PYHSS_REST_PORT:-8080}"; then
        HSS_AUTH_PREP_DETAIL="PyHSS API not reachable at ${PYHSS_IP}:${PYHSS_REST_PORT:-8080}"
        return 1
    fi
    if ! container_is_running "mysql"; then
        HSS_AUTH_PREP_DETAIL="MySQL container not running"
        return 1
    fi

    _hss_delete_auth_subscribers
    local ok=true
    _hss_prepare_one_subscriber "$HSS_AUTH_IMSI" "$HSS_AUTH_MSISDN" "$HSS_AUTH_KI" || ok=false
    _hss_prepare_one_subscriber "$HSS_AUTH_NEG_IMSI" "$HSS_AUTH_NEG_MSISDN" "$HSS_AUTH_NEG_KI" || ok=false
    _hss_verify_one_subscriber "$HSS_AUTH_IMSI" "$HSS_AUTH_MSISDN" "$HSS_AUTH_KI" || ok=false
    _hss_verify_one_subscriber "$HSS_AUTH_NEG_IMSI" "$HSS_AUTH_NEG_MSISDN" "$HSS_AUTH_NEG_KI" || ok=false
    $ok
}

_hss_need_auth_subscribers() {
    local n
    for n in 2 3 4 5 6 7 9 10; do
        if should_run_test "$n"; then
            return 0
        fi
    done
    return 1
}

_hss_run_attach_json() {
    local imsi="$1"
    local ki="$2"
    local msisdn="$3"
    local port_offset="$4"
    HSS_SNIPPET_IMSI="$imsi" \
    HSS_SNIPPET_KI="$ki" \
    HSS_SNIPPET_OPC="$HSS_AUTH_OPC" \
    HSS_SNIPPET_MSISDN="$msisdn" \
    HSS_SNIPPET_PORT_OFFSET="$port_offset" \
    timeout 45 "$PYTHON_BIN" - 2>/dev/null <<'PY' || echo '{"attach": false, "error": "python attach runner failed"}'
import json, os, sys
sys.path.insert(0, '/opt/test')
os.environ.setdefault('MME_IP', os.getenv('MME_IP', '172.22.1.9'))
os.environ.setdefault('PCSCF_IP', os.getenv('PCSCF_IP', '172.22.1.21'))
os.environ.setdefault('LOCAL_IP', os.getenv('LOCAL_IP', '172.22.1.200'))
os.environ.setdefault('MCC', os.getenv('MCC', '001'))
os.environ.setdefault('MNC', os.getenv('MNC', '01'))
from ue_sim.ue_simulator import UESimulator
from ue_sim.config import Config
import logging
logging.disable(logging.WARNING)
ue = UESimulator(
    imsi=os.environ['HSS_SNIPPET_IMSI'],
    ki=os.environ['HSS_SNIPPET_KI'],
    opc=os.environ['HSS_SNIPPET_OPC'],
    msisdn=os.environ.get('HSS_SNIPPET_MSISDN', ''),
    sip_local_port=Config.SIP_LOCAL_PORT_BASE + int(os.environ.get('HSS_SNIPPET_PORT_OFFSET', '60')),
)
ok = ue.attach()
out = {
    'attach': ok,
    'ip': ue.ip_address,
    'eea': ue.selected_eea,
    'eia': ue.selected_eia,
    'attach_ms': round(ue.metrics.attach_time_ms, 1),
    'error_stage': ue.metrics.error_stage,
    'error': ue.metrics.error_message,
    'stage_times': ue.metrics.stage_times_ms,
}
try:
    ue.detach()
except Exception:
    pass
print(json.dumps(out))
PY
}

_hss_cleanup_auth_subscribers() {
    if [ "${HSS_AUTH_KEEP_SUBSCRIBERS:-0}" = "1" ] || [ "${_FEATURE_FAIL:-0}" -gt 0 ] 2>/dev/null; then
        log "HSS AUC Auth: keeping dedicated subscribers for inspection (IMSI ${HSS_AUTH_IMSI}, ${HSS_AUTH_NEG_IMSI})"
        return 0
    fi
    _hss_delete_auth_subscribers
}

_hss_auth_failure_context() {
    local imsi="$1"
    {
        docker logs --tail 140 mme 2>&1
        docker logs --tail 140 pyhss 2>&1
    } | grep -iE "${imsi}|s6a|diameter|auth|unknown|reject|error|failed" | tail -14 | tr '\n' ' '
}

run_hss_auc_tests() {
    start_feature "HSS AUC Auth"

    local prep_needed=false
    if _hss_need_auth_subscribers; then
        prep_needed=true
        if _hss_prepare_auth_subscribers; then
            HSS_AUTH_PREPARED=true
        else
            HSS_AUTH_PREPARED=false
        fi
    fi

    # TC-1: PyHSS REST + S6a Diameter ports reachable
    if should_run_test 1; then
        _TEST_NUM=1
        local rest_ok=false
        local dia_ok=false
        check_port "$PYHSS_IP" "${PYHSS_REST_PORT:-8080}" && rest_ok=true
        check_port "$PYHSS_IP" "${PYHSS_DIAMETER_PORT:-3868}" && dia_ok=true
        if $rest_ok && $dia_ok; then
            pass "PyHSS REST ${PYHSS_REST_PORT:-8080} and S6a Diameter ${PYHSS_DIAMETER_PORT:-3868} reachable"
        elif $rest_ok; then
            fail "PyHSS REST reachable but S6a Diameter port is not reachable" "Check PyHSS freeDiameter listener on ${PYHSS_IP}:${PYHSS_DIAMETER_PORT:-3868}"
        else
            fail "PyHSS REST API is not reachable" "Check PyHSS container and ${PYHSS_IP}:${PYHSS_REST_PORT:-8080}"
        fi
    fi

    # TC-2: Dedicated auth subscribers provisioned
    if should_run_test 2; then
        _TEST_NUM=2
        if $HSS_AUTH_PREPARED; then
            pass "Dedicated auth subscribers provisioned (${HSS_AUTH_IMSI}, ${HSS_AUTH_NEG_IMSI})"
        else
            fail "Dedicated auth subscriber provisioning failed" "${HSS_AUTH_PREP_DETAIL:-unknown provisioning failure}"
        fi
    fi

    # TC-3: AUC/subscriber mapping valid
    if should_run_test 3; then
        _TEST_NUM=3
        if ! $HSS_AUTH_PREPARED; then
            fail "AUC/subscriber mapping cannot be verified" "${HSS_AUTH_PREP_DETAIL:-subscriber preparation failed}"
        elif _hss_verify_one_subscriber "$HSS_AUTH_IMSI" "$HSS_AUTH_MSISDN" "$HSS_AUTH_KI" && \
             _hss_verify_one_subscriber "$HSS_AUTH_NEG_IMSI" "$HSS_AUTH_NEG_MSISDN" "$HSS_AUTH_NEG_KI"; then
            local state_a state_b
            state_a=$(_hss_auth_subscriber_state "$HSS_AUTH_IMSI")
            state_b=$(_hss_auth_subscriber_state "$HSS_AUTH_NEG_IMSI")
            pass "AUC/subscriber mappings valid for dedicated auth IMSIs"
            append_report_block "AUC mapping" "${HSS_AUTH_IMSI}: ${state_a}
${HSS_AUTH_NEG_IMSI}: ${state_b}"
        else
            fail "AUC/subscriber mapping mismatch" "${HSS_AUTH_PREP_DETAIL:-unknown DB mismatch}"
        fi
    fi

    # TC-4: Milenage vector derivation from provisioned AUC data
    if should_run_test 4; then
        _TEST_NUM=4
        if ! $HSS_AUTH_PREPARED; then
            fail "Milenage vector derivation skipped by missing AUC data" "${HSS_AUTH_PREP_DETAIL:-subscriber preparation failed}"
        elif ! _hss_ue_sim_import_ok; then
            skip "Milenage vector derivation" "Python UE simulator libraries not importable"
        else
            local vec
            vec=$(HSS_VECTOR_KI="$HSS_AUTH_KI" HSS_VECTOR_OPC="$HSS_AUTH_OPC" HSS_VECTOR_AMF="$HSS_AUTH_AMF" timeout 10 "$PYTHON_BIN" - 2>/dev/null <<'PY' || echo '{}'
import json, os, sys
sys.path.insert(0, '/opt/test')
from ue_sim.milenage import Milenage
key = bytes.fromhex(os.environ['HSS_VECTOR_KI'])
opc = bytes.fromhex(os.environ['HSS_VECTOR_OPC'])
rand = bytes.fromhex('00112233445566778899aabbccddeeff')
res, ak = Milenage.f2_f5(key, rand, opc)
print(json.dumps({
    'res': res.hex(),
    'ck': Milenage.f3(key, rand, opc).hex(),
    'ik': Milenage.f4(key, rand, opc).hex(),
    'ak': ak.hex(),
}))
PY
)
            local res ck ik ak
            res=$(_hss_json_get "$vec" "res")
            ck=$(_hss_json_get "$vec" "ck")
            ik=$(_hss_json_get "$vec" "ik")
            ak=$(_hss_json_get "$vec" "ak")
            if [ ${#res} -eq 16 ] && [ ${#ck} -eq 32 ] && [ ${#ik} -eq 32 ] && [ ${#ak} -eq 12 ]; then
                pass "Milenage derivation OK from provisioned AUC data (RES/CK/IK/AK lengths valid)"
                append_report_block "Milenage vector" "$vec"
            else
                fail "Milenage derivation failed" "Vector output: ${vec}"
            fi
        fi
    fi

    # TC-5: Positive EPC attach authenticates and negotiates NAS security
    if should_run_test 5; then
        _TEST_NUM=5
        if ! $HSS_AUTH_PREPARED; then
            fail "Positive attach cannot run" "${HSS_AUTH_PREP_DETAIL:-subscriber preparation failed}"
        elif ! _hss_ue_sim_import_ok; then
            skip "Positive attach authentication" "Python UE simulator libraries not importable"
        else
            local result att eea eia err stage
            result=$(_hss_run_attach_json "$HSS_AUTH_IMSI" "$HSS_AUTH_KI" "$HSS_AUTH_MSISDN" 61)
            att=$(_hss_json_get "$result" "attach")
            eea=$(_hss_json_get "$result" "eea")
            eia=$(_hss_json_get "$result" "eia")
            err=$(_hss_json_get "$result" "error")
            stage=$(_hss_json_get "$result" "error_stage")
            if [ "$att" = "True" ] && [ "$eia" != "0" ] && [ -n "$eia" ]; then
                pass "EPC AKA attach OK for ${HSS_AUTH_IMSI}; NAS security negotiated EEA${eea}/EIA${eia}"
                append_report_block "Attach auth evidence" "$result"
            elif [ "$att" = "True" ]; then
                fail "Attach succeeded but NAS integrity algorithm was not negotiated" "EEA=${eea}, EIA=${eia}, result=${result}"
            else
                fail "EPC AKA attach failed for ${HSS_AUTH_IMSI}" "stage=${stage}, error=${err}; context=$(_hss_auth_failure_context "$HSS_AUTH_IMSI")"
            fi
        fi
    fi

    # TC-6: AUC SQN advances after successful attach
    if should_run_test 6; then
        _TEST_NUM=6
        if ! $HSS_AUTH_PREPARED; then
            fail "AUC SQN advancement cannot run" "${HSS_AUTH_PREP_DETAIL:-subscriber preparation failed}"
        elif ! _hss_ue_sim_import_ok; then
            skip "AUC SQN advancement" "Python UE simulator libraries not importable"
        else
            local before after result att
            before=$(_hss_mysql_scalar "SELECT COALESCE(sqn,-1) FROM auc WHERE imsi='${HSS_AUTH_IMSI}' LIMIT 1;")
            result=$(_hss_run_attach_json "$HSS_AUTH_IMSI" "$HSS_AUTH_KI" "$HSS_AUTH_MSISDN" 62)
            after=$(_hss_mysql_scalar "SELECT COALESCE(sqn,-1) FROM auc WHERE imsi='${HSS_AUTH_IMSI}' LIMIT 1;")
            att=$(_hss_json_get "$result" "attach")
            if [ "$att" = "True" ] && [ "$after" -gt "$before" ] 2>/dev/null; then
                pass "AUC SQN advanced after AKA attach (${before} -> ${after})"
            elif [ "$att" = "True" ]; then
                fail "Attach succeeded but AUC SQN did not advance" "before=${before}, after=${after}"
            else
                fail "AUC SQN advancement cannot be proven because attach failed" "${result}; context=$(_hss_auth_failure_context "$HSS_AUTH_IMSI")"
            fi
        fi
    fi

    # TC-7: Valid IMSI with wrong Ki is rejected
    if should_run_test 7; then
        _TEST_NUM=7
        if ! $HSS_AUTH_PREPARED; then
            fail "Wrong-Ki rejection cannot run" "${HSS_AUTH_PREP_DETAIL:-subscriber preparation failed}"
        elif ! _hss_ue_sim_import_ok; then
            skip "Wrong-Ki rejection" "Python UE simulator libraries not importable"
        else
            local result att err stage
            result=$(_hss_run_attach_json "$HSS_AUTH_NEG_IMSI" "$HSS_AUTH_WRONG_KI" "$HSS_AUTH_NEG_MSISDN" 63)
            att=$(_hss_json_get "$result" "attach")
            err=$(_hss_json_get "$result" "error")
            stage=$(_hss_json_get "$result" "error_stage")
            if [ "$att" = "False" ]; then
                pass "Wrong Ki rejected for valid IMSI ${HSS_AUTH_NEG_IMSI} (stage=${stage:-auth}, error=${err:-expected failure})"
            else
                fail "SECURITY: valid IMSI with wrong Ki was accepted" "$result"
            fi
        fi
    fi

    # TC-8: Unknown IMSI is rejected
    if should_run_test 8; then
        _TEST_NUM=8
        if ! _hss_ue_sim_import_ok; then
            skip "Unknown IMSI rejection" "Python UE simulator libraries not importable"
        else
            local result att
            result=$(_hss_run_attach_json "$HSS_AUTH_UNKNOWN_IMSI" "$HSS_AUTH_WRONG_KI" "$HSS_AUTH_UNKNOWN_MSISDN" 64)
            att=$(_hss_json_get "$result" "attach")
            if [ "$att" = "False" ]; then
                pass "Unknown IMSI ${HSS_AUTH_UNKNOWN_IMSI} correctly rejected"
            else
                fail "SECURITY: unknown IMSI was accepted" "$result"
            fi
        fi
    fi

    # TC-9: SQN re-synchronisation via AUTS succeeds
    if should_run_test 9; then
        _TEST_NUM=9
        if ! $HSS_AUTH_PREPARED; then
            fail "SQN resync cannot run" "${HSS_AUTH_PREP_DETAIL:-subscriber preparation failed}"
        elif ! _hss_ue_sim_import_ok; then
            skip "SQN resync via AUTS" "Python UE simulator libraries not importable"
        else
            local result ok before after err
            before=$(_hss_mysql_scalar "SELECT COALESCE(sqn,-1) FROM auc WHERE imsi='${HSS_AUTH_IMSI}' LIMIT 1;")
            result=$(HSS_SNIPPET_IMSI="$HSS_AUTH_IMSI" HSS_SNIPPET_KI="$HSS_AUTH_KI" HSS_SNIPPET_OPC="$HSS_AUTH_OPC" HSS_SNIPPET_MSISDN="$HSS_AUTH_MSISDN" timeout 60 "$PYTHON_BIN" - 2>/dev/null <<'PY' || echo '{"attach_resync": false, "error": "python resync runner failed"}'
import json, os, sys
sys.path.insert(0, '/opt/test')
os.environ.setdefault('MME_IP', os.getenv('MME_IP', '172.22.1.9'))
os.environ.setdefault('PCSCF_IP', os.getenv('PCSCF_IP', '172.22.1.21'))
os.environ.setdefault('LOCAL_IP', os.getenv('LOCAL_IP', '172.22.1.200'))
os.environ.setdefault('MCC', os.getenv('MCC', '001'))
os.environ.setdefault('MNC', os.getenv('MNC', '01'))
from ue_sim.ue_simulator import UESimulator
from ue_sim.config import Config
import logging
logging.disable(logging.WARNING)
ue = UESimulator(
    imsi=os.environ['HSS_SNIPPET_IMSI'],
    ki=os.environ['HSS_SNIPPET_KI'],
    opc=os.environ['HSS_SNIPPET_OPC'],
    msisdn=os.environ.get('HSS_SNIPPET_MSISDN', ''),
    sip_local_port=Config.SIP_LOCAL_PORT_BASE + 65,
)
ok = ue.attach_with_auts_resync(sqn_ue=bytes.fromhex('000000ffffff'))
out = {'attach_resync': ok, 'ip': ue.ip_address, 'error_stage': ue.metrics.error_stage, 'error': ue.metrics.error_message}
try:
    ue.detach()
except Exception:
    pass
print(json.dumps(out))
PY
)
            after=$(_hss_mysql_scalar "SELECT COALESCE(sqn,-1) FROM auc WHERE imsi='${HSS_AUTH_IMSI}' LIMIT 1;")
            ok=$(_hss_json_get "$result" "attach_resync")
            err=$(_hss_json_get "$result" "error")
            if [ "$ok" = "True" ]; then
                pass "SQN resync succeeded via AUTS; attach completed after second auth (SQN ${before} -> ${after})"
                append_report_block "AUTS resync evidence" "$result"
            else
                fail "SQN resync via AUTS failed" "${err:-no error}; result=${result}; SQN ${before}->${after}"
            fi
        fi
    fi

    # TC-10: IMS AKA registration succeeds for auth subscriber
    if should_run_test 10; then
        _TEST_NUM=10
        if ! $HSS_AUTH_PREPARED; then
            fail "IMS AKA registration cannot run" "${HSS_AUTH_PREP_DETAIL:-subscriber preparation failed}"
        elif ! _hss_ue_sim_import_ok; then
            skip "IMS AKA registration" "Python UE simulator libraries not importable"
        else
            local result att reg err
            result=$(HSS_SNIPPET_IMSI="$HSS_AUTH_IMSI" HSS_SNIPPET_KI="$HSS_AUTH_KI" HSS_SNIPPET_OPC="$HSS_AUTH_OPC" HSS_SNIPPET_MSISDN="$HSS_AUTH_MSISDN" timeout 45 "$PYTHON_BIN" - 2>/dev/null <<'PY' || echo '{"attach": false, "register": false, "error": "python IMS runner failed"}'
import json, os, sys
sys.path.insert(0, '/opt/test')
os.environ.setdefault('MME_IP', os.getenv('MME_IP', '172.22.1.9'))
os.environ.setdefault('PCSCF_IP', os.getenv('PCSCF_IP', '172.22.1.21'))
os.environ.setdefault('PYHSS_IP', os.getenv('PYHSS_IP', '172.22.1.18'))
os.environ.setdefault('LOCAL_IP', os.getenv('LOCAL_IP', '172.22.1.200'))
os.environ.setdefault('MCC', os.getenv('MCC', '001'))
os.environ.setdefault('MNC', os.getenv('MNC', '01'))
from ue_sim.ue_simulator import UESimulator
from ue_sim.config import Config
import logging
logging.disable(logging.WARNING)
ue = UESimulator(
    imsi=os.environ['HSS_SNIPPET_IMSI'],
    ki=os.environ['HSS_SNIPPET_KI'],
    opc=os.environ['HSS_SNIPPET_OPC'],
    msisdn=os.environ.get('HSS_SNIPPET_MSISDN', ''),
    sip_local_port=Config.SIP_LOCAL_PORT_BASE + 66,
)
ok_a = ue.attach()
ok_r = ue.ims_register() if ok_a else False
out = {'attach': ok_a, 'register': ok_r, 'error_stage': ue.metrics.error_stage, 'error': ue.metrics.error_message}
try:
    ue.detach()
except Exception:
    pass
print(json.dumps(out))
PY
)
            att=$(_hss_json_get "$result" "attach")
            reg=$(_hss_json_get "$result" "register")
            err=$(_hss_json_get "$result" "error")
            if [ "$att" = "True" ] && [ "$reg" = "True" ]; then
                pass "IMS AKA registration OK for ${HSS_AUTH_IMSI} (attach + REGISTER challenge/response succeeded)"
                append_report_block "IMS AKA evidence" "$result"
            elif [ "$att" = "True" ]; then
                fail "IMS AKA registration failed after successful EPC attach" "${err:-no error}; result=${result}"
            else
                fail "IMS AKA registration cannot start because EPC attach failed" "$result"
            fi
        fi
    fi

    if $prep_needed; then
        _hss_cleanup_auth_subscribers
    fi

    end_feature
}
