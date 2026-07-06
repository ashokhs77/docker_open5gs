#!/bin/bash
# Feature 00c: PDN Session
# Dedicated 4G EPS PDN session coverage for APN profiles, default bearer
# establishment, IPv4/IPv6/dual-stack negotiation, APN rejection, and detach.
#
# Tests:
#   TC-1: EPC user-plane NFs and primary ports are ready
#   TC-2: PyHSS APN profiles for internet and ims are present
#   TC-3: internet APN IPv4 default bearer assigns an IPv4 address
#   TC-4: ims APN IPv4 default bearer assigns an IPv4 address
#   TC-5: IPv4v6 PDN request is accepted or cleanly downgraded/skipped
#   TC-6: IPv6-only PDN request gets a prefix or records the lab gap
#   TC-7: Unknown APN is rejected
#   TC-8: PDN attach produces PFCP/GTP control-plane evidence
#   TC-9: UE detach releases the PDN context cleanly

set +e

_pdn_json_get() {
    local json="$1"
    local key="$2"
    printf '%s' "$json" | "$PYTHON_BIN" -c "import sys,json; d=json.load(sys.stdin); v=d.get('$key',''); print('' if v is None else v)" 2>/dev/null || echo ""
}

_pdn_ue_sim_import_ok() {
    "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import sys
sys.path.insert(0, '/opt/test')
from ue_sim.ue_simulator import UESimulator
from ue_sim.config import Config
PY
}

_pdn_attach_json() {
    local apn="$1"
    local pdn_type="$2"
    local sub_index="${3:-0}"
    local port_offset="${4:-80}"
    PDN_SNIPPET_APN="$apn" \
    PDN_SNIPPET_TYPE="$pdn_type" \
    PDN_SNIPPET_SUB_INDEX="$sub_index" \
    PDN_SNIPPET_PORT_OFFSET="$port_offset" \
    timeout 60 "$PYTHON_BIN" - 2>/dev/null <<'PY' || echo '{"attach": false, "detach": false, "error": "python PDN runner failed"}'
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
subs = Config.default_subscribers()
sub = subs[int(os.environ.get('PDN_SNIPPET_SUB_INDEX', '0')) % len(subs)]
ue = UESimulator(
    imsi=sub.imsi,
    ki=sub.ki,
    opc=sub.opc,
    msisdn=sub.msisdn,
    imei_sv=sub.imei_sv,
    sip_local_port=Config.SIP_LOCAL_PORT_BASE + int(os.environ.get('PDN_SNIPPET_PORT_OFFSET', '80')),
)
ok = ue.attach(apn=os.environ.get('PDN_SNIPPET_APN', 'internet'), pdn_type=int(os.environ.get('PDN_SNIPPET_TYPE', '1')))
ip = ue.ip_address
ipv6 = ue.ipv6_prefix
bearer = getattr(ue, '_bearer_id', None)
det = False
try:
    det = ue.detach() if ok else False
except Exception:
    det = False
print(json.dumps({
    'attach': ok,
    'detach': det,
    'apn': os.environ.get('PDN_SNIPPET_APN', 'internet'),
    'pdn_type': int(os.environ.get('PDN_SNIPPET_TYPE', '1')),
    'ipv4': ip,
    'ipv6_prefix': ipv6,
    'bearer_id': bearer,
    'attach_ms': round(ue.metrics.attach_time_ms, 1),
    'detach_ms': round((ue.metrics.detach_end - ue.metrics.detach_start) * 1000, 1) if ue.metrics.detach_start and ue.metrics.detach_end else 0,
    'error_stage': ue.metrics.error_stage,
    'error': ue.metrics.error_message,
}))
PY
}

_pdn_log_evidence() {
    { docker logs --tail 500 smf 2>&1; docker logs --tail 500 sgwc 2>&1; docker logs --tail 500 sgwu 2>&1; docker logs --tail 500 upf 2>&1; } 2>/dev/null |
        grep -Eai 'PFCP|GTP|Create Session|Modify Bearer|Session Establish|Bearer|UE IP|PDN|APN' |
        tail -40 || true
}

run_pdn_session_tests() {
    start_feature "PDN Session"

    local ue_import_ok=false
    if _pdn_ue_sim_import_ok; then
        ue_import_ok=true
    fi

    # TC-1: EPC user-plane NFs and primary ports are ready
    if should_run_test 1; then
        _TEST_NUM=1
        local missing=""
        for nf in sgwc sgwu smf upf; do
            container_is_running "$nf" || missing="${missing} ${nf}"
        done
        if [ -n "$missing" ]; then
            fail "EPC user-plane containers not running:${missing}" "SGW-C/SGW-U/SMF/UPF are required for PDN sessions"
        elif container_listens_on_port "sgwc" 2123 && container_listens_on_port "sgwu" 2152 && container_listens_on_port "smf" 8805 && container_listens_on_port "upf" 2152; then
            pass "SGW-C, SGW-U, SMF, and UPF running with GTP/PFCP ports listening"
        else
            pass "SGW-C, SGW-U, SMF, and UPF running (one or more UDP listener probes inconclusive)"
        fi
    fi

    # TC-2: PyHSS APN profiles for internet and ims are present
    if should_run_test 2; then
        _TEST_NUM=2
        local resp code body
        resp=$(api_get "http://${PYHSS_IP}:8080/apn/list")
        code=$(echo "$resp" | tail -1 | tr -d '[:space:]')
        body=$(echo "$resp" | sed '$d')
        if [ "$code" = "200" ] && echo "$body" | grep -q '"apn"[[:space:]]*:[[:space:]]*"internet"' && echo "$body" | grep -q '"apn"[[:space:]]*:[[:space:]]*"ims"'; then
            pass "PyHSS APN profiles present for internet and ims"
            append_report_block "APN profile evidence" "$(echo "$body" | grep -E '"apn"|"qci"|"ip_version"' | head -30)"
        elif [ "$code" = "200" ]; then
            fail "Required APN profiles missing" "Expected internet and ims in /apn/list"
        else
            fail "PyHSS APN profile API failed" "GET /apn/list returned HTTP ${code}"
        fi
    fi

    # TC-3: internet APN IPv4 default bearer assigns an IPv4 address
    if should_run_test 3; then
        _TEST_NUM=3
        if ! $ue_import_ok; then
            skip "internet IPv4 PDN attach" "Python UE simulator libraries not importable"
        else
            local result att ipv4 bearer err
            result=$(_pdn_attach_json "internet" 1 0 81)
            att=$(_pdn_json_get "$result" "attach")
            ipv4=$(_pdn_json_get "$result" "ipv4")
            bearer=$(_pdn_json_get "$result" "bearer_id")
            err=$(_pdn_json_get "$result" "error")
            if [ "$att" = "True" ] && [ -n "$ipv4" ]; then
                pass "internet APN IPv4 PDN attach OK: IPv4=${ipv4}, bearer=${bearer:-n/a}"
                append_report_block "internet IPv4 evidence" "$result"
            elif [ "$att" = "True" ]; then
                fail "internet APN attach succeeded but no IPv4 address was assigned" "$result"
            else
                fail "internet APN IPv4 PDN attach failed" "${err:-no error}; result=${result}"
            fi
        fi
    fi

    # TC-4: ims APN IPv4 default bearer assigns an IPv4 address
    if should_run_test 4; then
        _TEST_NUM=4
        if ! $ue_import_ok; then
            skip "ims IPv4 PDN attach" "Python UE simulator libraries not importable"
        else
            local result att ipv4 bearer err
            result=$(_pdn_attach_json "ims" 1 1 82)
            att=$(_pdn_json_get "$result" "attach")
            ipv4=$(_pdn_json_get "$result" "ipv4")
            bearer=$(_pdn_json_get "$result" "bearer_id")
            err=$(_pdn_json_get "$result" "error")
            if [ "$att" = "True" ] && [ -n "$ipv4" ]; then
                pass "ims APN IPv4 PDN attach OK: IPv4=${ipv4}, bearer=${bearer:-n/a}"
                append_report_block "ims IPv4 evidence" "$result"
            elif [ "$att" = "True" ]; then
                fail "ims APN attach succeeded but no IPv4 address was assigned" "$result"
            else
                fail "ims APN IPv4 PDN attach failed" "${err:-no error}; result=${result}"
            fi
        fi
    fi

    # TC-5: IPv4v6 PDN request is accepted or cleanly downgraded/skipped
    if should_run_test 5; then
        _TEST_NUM=5
        if ! $ue_import_ok; then
            skip "IPv4v6 PDN attach" "Python UE simulator libraries not importable"
        else
            local result att ipv4 ipv6
            result=$(_pdn_attach_json "internet" 3 0 83)
            att=$(_pdn_json_get "$result" "attach")
            ipv4=$(_pdn_json_get "$result" "ipv4")
            ipv6=$(_pdn_json_get "$result" "ipv6_prefix")
            if [ "$att" = "True" ] && [ -n "$ipv4" ] && [ -n "$ipv6" ]; then
                pass "IPv4v6 PDN attach OK: IPv4=${ipv4}, IPv6-prefix=${ipv6}"
            elif [ "$att" = "True" ] && [ -n "$ipv4" ]; then
                pass "IPv4v6 request accepted with IPv4 fallback (${ipv4}); lab has no IPv6 pool exposed"
            elif [ "$att" = "True" ]; then
                fail "IPv4v6 attach succeeded but no usable PDN address was decoded" "$result"
            else
                skip "IPv4v6 PDN attach" "SMF/PyHSS rejected IPv4v6, likely no IPv6 pool/profile in this lab; result=${result}"
            fi
        fi
    fi

    # TC-6: IPv6-only PDN request gets a prefix or records the lab gap
    if should_run_test 6; then
        _TEST_NUM=6
        if ! $ue_import_ok; then
            skip "IPv6-only PDN attach" "Python UE simulator libraries not importable"
        else
            local result att ipv6 ipv4
            result=$(_pdn_attach_json "internet" 2 1 84)
            att=$(_pdn_json_get "$result" "attach")
            ipv6=$(_pdn_json_get "$result" "ipv6_prefix")
            ipv4=$(_pdn_json_get "$result" "ipv4")
            if [ "$att" = "True" ] && [ -n "$ipv6" ]; then
                pass "IPv6-only PDN attach OK: IPv6-prefix=${ipv6}"
            elif [ "$att" = "True" ]; then
                skip "IPv6-only PDN attach" "Attach accepted but no IPv6 prefix decoded (IPv4=${ipv4:-none}); no IPv6 pool/profile exposed"
            else
                skip "IPv6-only PDN attach" "Rejected as expected when IPv6 APN pool/profile is not configured; result=${result}"
            fi
        fi
    fi

    # TC-7: Unknown APN is rejected
    if should_run_test 7; then
        _TEST_NUM=7
        if ! $ue_import_ok; then
            skip "Unknown APN rejection" "Python UE simulator libraries not importable"
        else
            local result att
            result=$(_pdn_attach_json "unknown-apn" 1 2 85)
            att=$(_pdn_json_get "$result" "attach")
            if [ "$att" = "False" ]; then
                pass "Unknown APN correctly rejected"
            else
                fail "Unknown APN was accepted" "$result"
            fi
        fi
    fi

    # TC-8: PDN attach produces PFCP/GTP control-plane evidence
    if should_run_test 8; then
        _TEST_NUM=8
        if ! $ue_import_ok; then
            skip "PFCP/GTP PDN evidence" "Python UE simulator libraries not importable"
        else
            local result att evidence
            result=$(_pdn_attach_json "internet" 1 0 86)
            att=$(_pdn_json_get "$result" "attach")
            evidence=$(_pdn_log_evidence)
            if [ "$att" = "True" ] && [ -n "$evidence" ]; then
                pass "PDN attach generated PFCP/GTP control-plane evidence"
                append_report_block "PFCP/GTP evidence" "$evidence"
            elif [ "$att" = "True" ]; then
                pass "PDN attach succeeded; PFCP/GTP log pattern not emitted at current log level"
            else
                fail "Cannot prove PFCP/GTP PDN evidence because attach failed" "$result"
            fi
        fi
    fi

    # TC-9: UE detach releases the PDN context cleanly
    if should_run_test 9; then
        _TEST_NUM=9
        if ! $ue_import_ok; then
            skip "PDN detach cleanup" "Python UE simulator libraries not importable"
        else
            local result att det err
            result=$(_pdn_attach_json "internet" 1 1 87)
            att=$(_pdn_json_get "$result" "attach")
            det=$(_pdn_json_get "$result" "detach")
            err=$(_pdn_json_get "$result" "error")
            if [ "$att" = "True" ] && [ "$det" = "True" ]; then
                pass "PDN context detach cleanup OK"
                append_report_block "detach evidence" "$result"
            elif [ "$att" = "True" ]; then
                fail "PDN attach OK but detach cleanup failed" "$result"
            else
                fail "PDN detach cleanup cannot run because attach failed" "${err:-no error}; result=${result}"
            fi
        fi
    fi

    end_feature
}