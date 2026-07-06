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
    sed "s/IMS_DOMAIN/${IMS_DOMAIN}/g" "$scenario" > "$tmp_scenario"

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
