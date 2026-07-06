#!/bin/bash
# Feature 14: Mobile-to-IP User (same IMS)
# Validates a mobile-originated IMS call toward a softphone or plain SIP user
# that is already registered within the same IMS domain. This is intentionally
# separate from the paused FXO/FXS path and focuses on the normal terminating
# MT route inside the IMS.
#
# Environment:
#   SOFTPHONE_TARGET_URI      required, e.g. sip:alice@ims.mnc001.mcc001.3gppnetwork.org
#   SOFTPHONE_TARGET_LABEL    optional display label for reports
#   SOFTPHONE_EXPECT_ANSWER   optional, default true
#   SOFTPHONE_CALL_DURATION   optional, default 5
#
# TC-1: Target softphone URI configured
# TC-2: P-CSCF terminating route configuration sanity
# TC-3: S-CSCF local terminating lookup configuration sanity
# TC-4: Mobile UE attach + IMS register for same-IMS softphone scenario
# TC-5: Mobile-originated call to same-IMS softphone target
# TC-6: Current-run MT and media evidence for the softphone call

set +e

source /opt/test/lib/common.sh

MOBILE_IP_SINCE=""
MOBILE_IP_ATTACH_JSON=""
MOBILE_IP_CALL_JSON=""

mobile_ip_target_uri() {
    printf '%s' "${SOFTPHONE_TARGET_URI:-}" | tr -d '\r'
}

mobile_ip_target_label() {
    local target
    target="$(mobile_ip_target_uri)"
    if [ -n "${SOFTPHONE_TARGET_LABEL:-}" ]; then
        printf '%s' "$SOFTPHONE_TARGET_LABEL"
    else
        printf '%s' "$target"
    fi
}

mobile_ip_target_user() {
    local target
    target="$(mobile_ip_target_uri)"
    target="${target#sip:}"
    target="${target#<}"
    target="${target%>}"
    target="${target%%;*}"
    target="${target%%\?*}"
    target="${target%%@*}"
    printf '%s' "$target"
}

mobile_ip_escape_regex() {
    printf '%s' "$1" | sed 's/[][(){}.^$*+?|\\/]/\\&/g'
}

mobile_ip_reason_unconfigured() {
    echo "Set SOFTPHONE_TARGET_URI to a same-IMS registered SIP user to enable this feature"
}

mobile_ip_capture_evidence() {
    local title="$1"
    local target_user
    target_user="$(mobile_ip_target_user)"
    local user_regex
    user_regex="$(mobile_ip_escape_regex "$target_user")"

    dump_container_log_matches \
        "pcscf" \
        "${title} P-CSCF MT" \
        "Destination URI|Request URI|IMS SIP client DOING RX IN MT|Skipping Rx media authorization - Non-IMS SIP client|${user_regex}" \
        40 \
        "$MOBILE_IP_SINCE"

    dump_container_log_matches \
        "scscf" \
        "${title} S-CSCF Final Term" \
        "\\[FINAL_TERM\\]|lookup\\(\"location\"\\)|User not registered locally|${user_regex}" \
        40 \
        "$MOBILE_IP_SINCE"

    capture_media_path_evidence "${title} Media Path" "${user_regex}|offer|answer|delete|m=audio|m=video" 30 "$MOBILE_IP_SINCE"
}

mobile_ip_attach_register_probe() {
    MOBILE_IP_ATTACH_JSON=$(
        timeout 60 env \
            MOBILE_IP_TARGET_URI_ENV="$(mobile_ip_target_uri)" \
            "$PYTHON_BIN" - <<'PY'
import json
import logging
import os
import sys

sys.path.insert(0, "/opt/test")
from ue_sim.ue_simulator import UESimulator
from ue_sim.config import Config

logging.disable(logging.WARNING)
sub = Config.default_subscribers()[0]
ue = UESimulator(
    imsi=sub.imsi,
    ki=sub.ki,
    opc=sub.opc,
    msisdn=sub.msisdn,
    sip_local_port=Config.SIP_LOCAL_PORT_BASE + 70,
)
ok_attach = ue.attach()
ok_register = ue.ims_register() if ok_attach else False
ue.detach()
print(json.dumps({
    "attach": ok_attach,
    "register": ok_register,
    "error": ue.metrics.error_message,
}))
PY
    )
    if [ $? -ne 0 ] || [ -z "$MOBILE_IP_ATTACH_JSON" ]; then
        MOBILE_IP_ATTACH_JSON='{"attach":false,"register":false,"error":"probe execution failed"}'
    fi
}

mobile_ip_call_probe() {
    MOBILE_IP_CALL_JSON=$(
        timeout 90 env \
            SOFTPHONE_TARGET_URI_ENV="$(mobile_ip_target_uri)" \
            SOFTPHONE_CALL_DURATION_ENV="${SOFTPHONE_CALL_DURATION:-5}" \
            "$PYTHON_BIN" - <<'PY'
import json
import logging
import os
import sys

sys.path.insert(0, "/opt/test")
from ue_sim.ue_simulator import UESimulator
from ue_sim.config import Config

logging.disable(logging.WARNING)
target = os.getenv("SOFTPHONE_TARGET_URI_ENV", "")
duration = float(os.getenv("SOFTPHONE_CALL_DURATION_ENV", "5"))
sub = Config.default_subscribers()[0]
ue = UESimulator(
    imsi=sub.imsi,
    ki=sub.ki,
    opc=sub.opc,
    msisdn=sub.msisdn,
    sip_local_port=Config.SIP_LOCAL_PORT_BASE + 72,
)
ok_attach = ue.attach()
ok_register = ue.ims_register() if ok_attach else False
ok_call = False
if ok_register and target:
    ok_call = ue.volte_call(target, duration=duration)
ue.detach()
print(json.dumps({
    "attach": ok_attach,
    "register": ok_register,
    "call": ok_call,
    "error": ue.metrics.error_message,
}))
PY
    )
    if [ $? -ne 0 ] || [ -z "$MOBILE_IP_CALL_JSON" ]; then
        MOBILE_IP_CALL_JSON='{"attach":false,"register":false,"call":false,"error":"call probe execution failed"}'
    fi
}

run_mobile_ip_tests() {
    start_feature "Mobile-to-IP"

    local target_uri
    target_uri="$(mobile_ip_target_uri)"
    local target_label
    target_label="$(mobile_ip_target_label)"
    local target_user
    target_user="$(mobile_ip_target_user)"
    local expect_answer
    expect_answer=$(printf '%s' "${SOFTPHONE_EXPECT_ANSWER:-true}" | tr '[:upper:]' '[:lower:]')
    local skip_reason
    skip_reason="$(mobile_ip_reason_unconfigured)"

    # TC-1: target configured
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Same-IMS softphone target configuration"
        if [ -z "$target_uri" ]; then
            skip "Mobile-to-IP target not configured" "$skip_reason"
        elif ! printf '%s' "$target_uri" | grep -qiE '^sip:[^@]+@[^@]+$'; then
            fail "Softphone target URI is invalid" "Expected sip:user@domain, got: ${target_uri}"
        else
            pass "Softphone target configured (${target_label})"
        fi
    fi

    # TC-2: P-CSCF MT route sanity
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: P-CSCF MT route configuration"
        if [ -z "$target_uri" ]; then
            skip "P-CSCF MT route configuration" "$skip_reason"
        else
            local mt_cfg
            mt_cfg=$(docker exec pcscf sh -c "grep -n 'route\\[MT\\]\\|t_on_reply(\"MT_reply\")\\|Skipping Rx media authorization - Non-IMS SIP client\\|IMS SIP client DOING RX IN MT' /mnt/pcscf/route/mt.cfg 2>/dev/null || grep -n 'route\\[MT\\]\\|t_on_reply(\"MT_reply\")\\|Skipping Rx media authorization - Non-IMS SIP client\\|IMS SIP client DOING RX IN MT' /etc/kamailio/route/mt.cfg 2>/dev/null" 2>/dev/null || true)
            if echo "$mt_cfg" | grep -q 'route\[MT\]' && echo "$mt_cfg" | grep -q 'MT_reply'; then
                append_report_block "P-CSCF MT route refs" "$mt_cfg"
                pass "P-CSCF MT route is configured for same-IMS terminating delivery"
            else
                append_report_block "P-CSCF MT route refs" "$mt_cfg"
                fail "P-CSCF MT route configuration not found" "route[MT] or MT_reply markers missing"
            fi
        fi
    fi

    # TC-3: S-CSCF local terminating lookup sanity
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: S-CSCF local terminating lookup configuration"
        if [ -z "$target_uri" ]; then
            skip "S-CSCF local terminating lookup configuration" "$skip_reason"
        else
            local scscf_cfg
            scscf_cfg=$(docker exec scscf sh -c "grep -n '\\[FINAL_TERM\\]\\|lookup(\"location\")\\|User not registered locally\\|t_relay()' /mnt/scscf/kamailio_scscf.cfg 2>/dev/null || grep -n '\\[FINAL_TERM\\]\\|lookup(\"location\")\\|User not registered locally\\|t_relay()' /etc/kamailio/kamailio_scscf.cfg 2>/dev/null" 2>/dev/null || true)
            if echo "$scscf_cfg" | grep -q '\[FINAL_TERM\]' && echo "$scscf_cfg" | grep -q 'lookup("location")'; then
                append_report_block "S-CSCF FINAL_TERM refs" "$scscf_cfg"
                pass "S-CSCF local terminating lookup is configured"
            else
                append_report_block "S-CSCF FINAL_TERM refs" "$scscf_cfg"
                fail "S-CSCF local terminating lookup markers missing" "FINAL_TERM / lookup(location) not found"
            fi
        fi
    fi

    # TC-4: attach + register preflight
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Mobile UE attach + IMS register for same-IMS softphone scenario"
        if [ -z "$target_uri" ]; then
            skip "Mobile UE attach + IMS register" "$skip_reason"
        elif ! ue_sim_probe; then
            skip "Python UE simulator not available" "$(ue_sim_probe_reason)"
        else
            MOBILE_IP_SINCE=$(log_cursor_now)
            mobile_ip_attach_register_probe
            local ok_attach
            ok_attach=$(echo "$MOBILE_IP_ATTACH_JSON" | "$PYTHON_BIN" -c "import sys,json; d=json.load(sys.stdin); print(d.get('attach', False))" 2>/dev/null || echo "False")
            local ok_register
            ok_register=$(echo "$MOBILE_IP_ATTACH_JSON" | "$PYTHON_BIN" -c "import sys,json; d=json.load(sys.stdin); print(d.get('register', False))" 2>/dev/null || echo "False")
            local err
            err=$(echo "$MOBILE_IP_ATTACH_JSON" | "$PYTHON_BIN" -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || echo "")

            if [ "$ok_attach" = "True" ] && [ "$ok_register" = "True" ]; then
                pass "Mobile UE attached and IMS registered for same-IMS softphone call"
            elif [ "$ok_attach" = "True" ]; then
                fail "Attach OK but IMS registration failed for same-IMS softphone scenario" "$err"
            else
                fail "Attach failed for same-IMS softphone scenario" "$err"
            fi
        fi
    fi

    # TC-5: mobile to softphone call
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Mobile-originated call to same-IMS softphone target"
        if [ -z "$target_uri" ]; then
            skip "Mobile-originated call to same-IMS softphone target" "$skip_reason"
        elif [ "$expect_answer" != "true" ]; then
            skip "Mobile-originated call to same-IMS softphone target" "Current automation expects the configured softphone to answer the call; set SOFTPHONE_EXPECT_ANSWER=true once that path is available"
        elif ! ue_sim_probe; then
            skip "Python UE simulator not available" "$(ue_sim_probe_reason)"
        else
            [ -n "$MOBILE_IP_SINCE" ] || MOBILE_IP_SINCE=$(log_cursor_now)
            mobile_ip_call_probe

            local ok_attach
            ok_attach=$(echo "$MOBILE_IP_CALL_JSON" | "$PYTHON_BIN" -c "import sys,json; d=json.load(sys.stdin); print(d.get('attach', False))" 2>/dev/null || echo "False")
            local ok_register
            ok_register=$(echo "$MOBILE_IP_CALL_JSON" | "$PYTHON_BIN" -c "import sys,json; d=json.load(sys.stdin); print(d.get('register', False))" 2>/dev/null || echo "False")
            local ok_call
            ok_call=$(echo "$MOBILE_IP_CALL_JSON" | "$PYTHON_BIN" -c "import sys,json; d=json.load(sys.stdin); print(d.get('call', False))" 2>/dev/null || echo "False")
            local err
            err=$(echo "$MOBILE_IP_CALL_JSON" | "$PYTHON_BIN" -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || echo "")

            if [ "$ok_attach" = "True" ] && [ "$ok_register" = "True" ] && [ "$ok_call" = "True" ]; then
                pass "Mobile-to-IP softphone call completed successfully (${target_label})"
            elif [ "$ok_attach" = "True" ] && [ "$ok_register" = "True" ]; then
                mobile_ip_capture_evidence "Mobile-to-IP failure"
                fail "Mobile UE reached call stage but the same-IMS softphone call did not complete" "$err"
            elif [ "$ok_attach" = "True" ]; then
                fail "Attach OK but IMS registration failed before softphone call" "$err"
            else
                fail "Attach failed before softphone call" "$err"
            fi
        fi
    fi

    # TC-6: MT/media evidence
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Current-run MT and media evidence for same-IMS softphone path"
        if [ -z "$target_uri" ]; then
            skip "Current-run MT and media evidence for same-IMS softphone path" "$skip_reason"
        elif [ "$expect_answer" != "true" ]; then
            skip "Current-run MT and media evidence for same-IMS softphone path" "Call-execution phase is disabled until the configured softphone is expected to answer"
        elif [ -z "$MOBILE_IP_SINCE" ]; then
            skip "Current-run MT and media evidence for same-IMS softphone path" "Call probe did not run"
        elif [ -z "$MOBILE_IP_CALL_JSON" ]; then
            skip "Current-run MT and media evidence for same-IMS softphone path" "Call probe did not complete"
        else
            local user_regex
            user_regex="$(mobile_ip_escape_regex "$target_user")"
            local pcscf_hits
            local scscf_hits

            pcscf_hits=$(docker_logs_grep_since "pcscf" "$MOBILE_IP_SINCE" "Destination URI|Request URI|IMS SIP client DOING RX IN MT|Skipping Rx media authorization - Non-IMS SIP client|${user_regex}" 30)
            scscf_hits=$(docker_logs_grep_since "scscf" "$MOBILE_IP_SINCE" "\\[FINAL_TERM\\]|User not registered locally|${user_regex}" 30)

            mobile_ip_capture_evidence "Mobile-to-IP evidence"

            if echo "$scscf_hits" | grep -q '\[FINAL_TERM\]' || echo "$pcscf_hits" | grep -q "$target_user"; then
                pass "Current-run terminating-path evidence captured for same-IMS softphone target (${target_label})"
            else
                fail "No current-run terminating-path evidence captured for same-IMS softphone target" "P-CSCF/S-CSCF logs did not show MT routing markers for ${target_label}"
            fi
        fi
    fi

    end_feature
}
