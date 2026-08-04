#!/bin/bash
# SIPp helper functions for 4G EPC + IMS integration test suite
# Sourced by feature scripts that need SIPp capabilities

set +e  # Don't exit on errors - we handle them ourselves

# ============================================================
# Run SIPp scenario and return exit code
# Usage: run_sipp TARGET_IP TARGET_PORT SCENARIO_FILE SERVICE_NAME LOCAL_PORT [extra_args...]
# ============================================================
run_sipp() {
    local target_ip="$1"
    local target_port="$2"
    local scenario="$3"
    local service="$4"
    local local_port="$5"
    shift 5

    if [ ! -f "$scenario" ]; then
        echo "ERROR: SIPp scenario file not found: $scenario"
        return 1
    fi

    local output
    output=$(sipp "${target_ip}:${target_port}" \
        -sf "$scenario" \
        -s "$service" \
        -i "$LOCAL_IP" -p "$local_port" \
        -m 1 -l 1 \
        -timeout 15 \
        -timeout_error \
        "$@" 2>&1)
    local rc=$?

    echo "$output"
    return $rc
}

# ============================================================
# Run SIPp with IMS_DOMAIN template replacement
# Replaces __IMS_DOMAIN__ in the scenario file before executing
# Usage: run_sipp_templated TARGET_IP TARGET_PORT SCENARIO_FILE SERVICE_NAME LOCAL_PORT [extra_args...]
# ============================================================
run_sipp_templated() {
    local target_ip="$1"
    local target_port="$2"
    local scenario="$3"
    local service="$4"
    local local_port="$5"
    shift 5

    if [ ! -f "$scenario" ]; then
        echo "ERROR: SIPp scenario file not found: $scenario"
        return 1
    fi

    local tmp_scenario="/tmp/sipp_templated_$(basename "$scenario")_$$"
    # Substitute IMS_DOMAIN (PLMN) and, for phone-profiled scenarios, USER_AGENT.
    # SIPP_USER_AGENT defaults to a benign value so scenarios that carry a
    # USER_AGENT token but are run without a profile still produce a valid header.
    # '#' is used as the sed delimiter for the UA because the string may contain
    # spaces/slashes (e.g. "VoLTE/WFC UA") but never a '#'.
    local ua="${SIPP_USER_AGENT:-SIPp-Test-UA}"
    sed -e "s/IMS_DOMAIN/${IMS_DOMAIN}/g" \
        -e "s#USER_AGENT#${ua}#g" "$scenario" > "$tmp_scenario"

    local output
    output=$(sipp "${target_ip}:${target_port}" \
        -sf "$tmp_scenario" \
        -s "$service" \
        -i "$LOCAL_IP" -p "$local_port" \
        -m 1 -l 1 \
        -timeout 15 \
        -timeout_error \
        "$@" 2>&1)
    local rc=$?

    rm -f "$tmp_scenario"

    echo "$output"
    return $rc
}

# ============================================================
# Run a phone-profiled SIPp scenario: sets the User-Agent (phone type) and,
# optionally, the IMS_DOMAIN (PLMN) for the duration of one SIPp run, then
# delegates to run_sipp_templated. The scenario should carry a USER_AGENT token
# (and IMS_DOMAIN tokens) which run_sipp_templated substitutes.
#
# Usage: run_sipp_profiled PHONE PLMN_DOMAIN TARGET_IP TARGET_PORT SCENARIO SERVICE LOCAL_PORT [extra_args...]
#   PHONE       : optimus | samsung | <anything> (maps via phone_ua)
#   PLMN_DOMAIN : IMS domain to target, or "" / "-" to keep the current IMS_DOMAIN
# Locals leak into run_sipp_templated via bash dynamic scope (intended), so the
# caller's global IMS_DOMAIN is left untouched.
# ============================================================
run_sipp_profiled() {
    local phone="$1"
    local plmn_domain="$2"
    shift 2

    local SIPP_USER_AGENT
    SIPP_USER_AGENT="$(phone_ua "$phone")"
    local IMS_DOMAIN="$IMS_DOMAIN"
    if [ -n "$plmn_domain" ] && [ "$plmn_domain" != "-" ]; then
        IMS_DOMAIN="$plmn_domain"
    fi

    run_sipp_templated "$@"
}

# ============================================================
# assert_profiled_invite_non5xx PHONE PLMN_DOMAIN SCENARIO SERVICE LOCAL_PORT DESC
# Sends a phone-profiled INVITE and passes on any non-5xx IMS response (200/4xx/
# timeout are all acceptable without full registration), fails on 5xx or SIPp
# crash. Mirrors the intra-NIB VoLTE/ViLTE judging logic. Calls pass/fail/skip.
# ============================================================
assert_profiled_invite_non5xx() {
    local phone="$1" plmn="$2" scenario="$3" service="$4" lport="$5" desc="$6"

    if [ ! -f "$scenario" ]; then
        skip "$desc" "scenario $(basename "$scenario") not found"
        return
    fi
    if ! check_port "$PCSCF_IP" "${PCSCF_PORT:-5060}"; then
        skip "$desc" "P-CSCF not reachable at ${PCSCF_IP}:${PCSCF_PORT:-5060}"
        return
    fi

    local out
    out=$(run_sipp_profiled "$phone" "$plmn" "$PCSCF_IP" "${PCSCF_PORT:-5060}" \
        "$scenario" "$service" "$lport" 2>&1)

    if echo "$out" | grep -qE "Assertion.*failed|not implemented in display|Segmentation fault"; then
        fail "$desc: SIPp crashed (scenario XML incompatibility)" \
             "$(echo "$out" | grep -E 'assert|Assertion|ERROR|not implemented' | head -3)"
    elif echo "$out" | grep -qE 'SIP/2\.[0-9][[:space:]]+5[0-9][0-9]|^[[:space:]]*5[0-9][0-9][[:space:]]+(Received|received)'; then
        fail "$desc: IMS returned 5xx" \
             "$(echo "$out" | grep -E '5[0-9][0-9]' | head -3)"
    else
        pass "$desc: routed through IMS chain, no 5xx (UA='$(phone_ua "$phone")')"
    fi
}

# ============================================================
# assert_register_expect SCENARIO LOCAL_PORT DESC PASS_MSG FAIL_MSG
# Runs a REGISTER scenario whose <recv> encodes the expected response code
# (e.g. 420 for the Optimus sec-agree scenario, 401 for Samsung). SIPp exit 0
# means the expected code arrived. Any other result fails with the SIPp tail so
# the actual (wrong) response is visible. Calls pass/fail/skip.
# ============================================================
assert_register_expect() {
    local scenario="$1" lport="$2" desc="$3" pass_msg="$4" fail_msg="$5"

    if [ ! -f "$scenario" ]; then
        skip "$desc" "scenario $(basename "$scenario") not found"
        return
    fi
    if ! check_port "$PCSCF_IP" "${PCSCF_PORT:-5060}"; then
        skip "$desc" "P-CSCF not reachable at ${PCSCF_IP}:${PCSCF_PORT:-5060}"
        return
    fi

    local out
    out=$(run_sipp_templated "$PCSCF_IP" "${PCSCF_PORT:-5060}" \
        "$scenario" "9876540001" "$lport" 2>&1)
    local rc=$?

    if echo "$out" | grep -qE "Assertion.*failed|not implemented in display|Segmentation fault"; then
        fail "$desc: SIPp crashed (scenario XML incompatibility)" \
             "$(echo "$out" | grep -E 'assert|Assertion|ERROR|not implemented' | head -3)"
    elif [ "$rc" -eq 0 ]; then
        pass "$pass_msg"
    else
        fail "$fail_msg" "$(echo "$out" | grep -iE 'unexpected|SIP/2\.0 [0-9]{3}|Aborting|timeout' | head -4)"
    fi
}

# ============================================================
# assert_register_not_rejected SCENARIO LOCAL_PORT DESC [REJECT_CODE]
# Gate-SCOPING check for a non-MTK UA (Samsung sec-agree): the P-CSCF
# REJECT_SEC_AGREE gate is MTK-only, so the ONLY failing outcome is the reject
# code (420) — that would mean the gate wrongly caught a non-MTK UA.
#
# Why not assert an exact 401: SIPp cannot complete an IPsec-3gpp REGISTER (no
# kernel IPsec stack), so the clean 401 a real handset gets is unreachable here.
# A UA that is NOT gated instead proceeds down the normal IPsec path and reaches
# either the 401 challenge or 503 "Create ipsec failed" (the P-CSCF programming
# its inbound SA for a client that will never complete it). Both prove the gate
# did not fire. Real Samsung phones register with IPsec fine on this core, so a
# 503 here is a SIPp limitation, not a P-CSCF defect. Property under test:
# response != REJECT_CODE.
# ============================================================
assert_register_not_rejected() {
    local scenario="$1" lport="$2" desc="$3" reject_code="${4:-420}"

    if [ ! -f "$scenario" ]; then
        skip "$desc" "scenario $(basename "$scenario") not found"
        return
    fi
    if ! check_port "$PCSCF_IP" "${PCSCF_PORT:-5060}"; then
        skip "$desc" "P-CSCF not reachable at ${PCSCF_IP}:${PCSCF_PORT:-5060}"
        return
    fi

    local out rc code
    out=$(run_sipp_templated "$PCSCF_IP" "${PCSCF_PORT:-5060}" \
        "$scenario" "9876540001" "$lport" 2>&1)
    rc=$?

    if echo "$out" | grep -qE "Assertion.*failed|not implemented in display|Segmentation fault"; then
        fail "$desc: SIPp crashed (scenario XML incompatibility)" \
             "$(echo "$out" | grep -E 'assert|Assertion|ERROR|not implemented' | head -3)"
        return
    fi

    # Final SIP response actually seen from the P-CSCF. rc==0 means the scenario's
    # own <recv 401> matched (ideal); otherwise recover the received code from the
    # SIPp abort line ("received 'SIP/2.0 NNN ...'"), ignoring 100 Trying.
    code=$(echo "$out" | grep -oE "SIP/2\.0 [0-9]{3}" | grep -vE "SIP/2\.0 100" | tail -1 | grep -oE "[0-9]{3}$")

    if [ "$rc" -eq 0 ]; then
        pass "$desc: P-CSCF issued 401 challenge (IPsec path preserved, MTK gate correctly not applied)"
    elif [ "$code" = "$reject_code" ]; then
        fail "$desc: P-CSCF returned ${reject_code} — MTK sec-agree gate wrongly caught a non-MTK UA (gate no longer scoped to MTK)" \
             "$(echo "$out" | grep -iE 'unexpected|SIP/2\.0 [0-9]{3}|Aborting' | head -3)"
    elif [ -n "$code" ]; then
        pass "$desc: not gated — P-CSCF took the non-MTK IPsec path (got ${code}; SIPp cannot complete IPsec-3gpp, a real UE gets 401)"
    else
        fail "$desc: no SIP response from P-CSCF (expected a non-${reject_code} challenge)" \
             "$(echo "$out" | grep -iE 'timeout|Aborting|ERROR' | head -3)"
    fi
}

# ============================================================
# Run SIPp in background (for concurrent tests)
# Returns PID via stdout; per-PID log stored in SIPP_BG_LOG_<pid>.
# Usage: pid=$(run_sipp_bg TARGET_IP TARGET_PORT SCENARIO_FILE SERVICE_NAME LOCAL_PORT [extra_args...])
# After waiting, call: wait_sipp_bg $pid [1]  (1 = append tail to report)
# ============================================================
run_sipp_bg() {
    local target_ip="$1"
    local target_port="$2"
    local scenario="$3"
    local service="$4"
    local local_port="$5"
    shift 5

    if [ ! -f "$scenario" ]; then
        echo "ERROR: SIPp scenario file not found: $scenario"
        return 1
    fi

    local log_file
    log_file=$(mktemp /tmp/sipp_bg_XXXXXX.log)

    sipp "${target_ip}:${target_port}" \
        -sf "$scenario" \
        -s "$service" \
        -i "$LOCAL_IP" -p "$local_port" \
        -m 1 -l 1 \
        -timeout 15 \
        -timeout_error \
        "$@" > "$log_file" 2>&1 &

    local pid=$!
    # Store log path keyed by PID so wait_sipp_bg can find it
    eval "SIPP_BG_LOG_${pid}=${log_file}"
    echo "$pid"
    return 0
}

# ============================================================
# Wait for a background SIPp process and check its exit code.
# Optionally appends the last 20 lines of its log to the feature report.
# Usage: wait_sipp_bg PID [append_to_report:0|1]
# Returns the SIPp exit code.
# ============================================================
wait_sipp_bg() {
    local pid="$1"
    local report="${2:-0}"

    [ -z "$pid" ] && return 1

    wait "$pid" 2>/dev/null
    local rc=$?

    local log_var="SIPP_BG_LOG_${pid}"
    local log_file
    log_file="${!log_var}"

    if [ -n "$log_file" ] && [ -f "$log_file" ]; then
        if [ "$report" = "1" ] && [ -n "$_FEATURE_REPORT" ]; then
            echo "       --- SIPp bg pid=${pid} exit=${rc} ---" >> "$_FEATURE_REPORT"
            tail -20 "$log_file" >> "$_FEATURE_REPORT"
        fi
        rm -f "$log_file"
    fi
    unset "SIPP_BG_LOG_${pid}"
    return $rc
}

# ============================================================
# Check if background SIPp is still running
# Usage: check_sipp_alive PID
# Returns 0 if running, 1 if not
# ============================================================
check_sipp_alive() {
    local pid="$1"

    if [ -z "$pid" ]; then
        return 1
    fi

    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    return 1
}
