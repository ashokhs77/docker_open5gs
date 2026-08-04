#!/bin/bash
# Common test helpers for 4G EPC + IMS integration test suite
# Sourced by all feature scripts

set +e  # Don't exit on errors - we handle them ourselves

# ============================================================
# Environment (from docker env or defaults)
# ============================================================
# Test topology: 'internal' (runner + core on same VM, default) or 'external'
# (runner on a separate generator VM targeting a remote core — see
# EXTERNAL_LOAD_GENERATOR_MODE.txt). Internal mode remains the default same-VM path.
TEST_TOPOLOGY="${TEST_TOPOLOGY:-internal}"
case "$TEST_TOPOLOGY" in
    internal|external) ;;
    *) TEST_TOPOLOGY="internal" ;;
esac
CORE_TARGET_LABEL="${CORE_TARGET_LABEL:-same-vm-docker}"
CORE_VM_HOST="${CORE_VM_HOST:-}"
LOAD_GENERATOR_IP="${LOAD_GENERATOR_IP:-}"
_LOCAL_IP_WAS_SET="${LOCAL_IP+x}"
LOCAL_IP_SOURCE="env"
PCSCF_IP="${PCSCF_IP:-172.22.1.21}"
PCSCF_PORT="${PCSCF_PORT:-5060}"
FREESWITCH_IP="${FREESWITCH_IP:-172.22.1.150}"
PYHSS_IP="${PYHSS_IP:-172.22.1.18}"
PYHSS_REST_PORT="${PYHSS_REST_PORT:-8080}"
# LOCAL_IP: bind/Contact/Via address. In internal mode the compose passes
# 172.22.1.200 (so this is a no-op). In external mode it is auto-derived from
# LOAD_GENERATOR_IP, then the route to PCSCF_IP, then a safe default.
if [ -z "${LOCAL_IP:-}" ] && [ -n "$LOAD_GENERATOR_IP" ]; then
    LOCAL_IP="$LOAD_GENERATOR_IP"
    LOCAL_IP_SOURCE="LOAD_GENERATOR_IP"
elif [ -z "${LOCAL_IP:-}" ] && [ "$TEST_TOPOLOGY" = "external" ] && command -v ip >/dev/null 2>&1; then
    LOCAL_IP=$(ip route get "$PCSCF_IP" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    [ -n "$LOCAL_IP" ] && LOCAL_IP_SOURCE="auto-route"
fi
if [ -z "${LOCAL_IP:-}" ]; then
    LOCAL_IP="172.22.1.200"
    LOCAL_IP_SOURCE="default"
fi
IMS_DOMAIN="${IMS_DOMAIN:-ims.mnc001.mcc001.3gppnetwork.org}"

# ============================================================
# PLMN & phone-type (UE profile) helpers
# ------------------------------------------------------------
# The core is deployed as ONE PLMN at a time (the DNS server serves a single
# ims.mncXXX.mccYYY zone derived from MNC/MCC at container init). The suite is
# therefore PLMN-parameterised via IMS_DOMAIN: deploy the core as 001-01 or
# 404-20 and point the runner at the matching IMS_DOMAIN. These helpers let the
# tests self-identify the active PLMN, verify it is one we support, and drive
# per-phone-type behaviour (Optimus/MTK vs Samsung) that the P-CSCF gates on the
# User-Agent (e.g. the sec-agree -> 420 fallback is MTK-only).
# ============================================================

# PLMNs this deployment is validated against. Space-separated "mcc-mnc" labels.
SUPPORTED_PLMNS="${SUPPORTED_PLMNS:-001-01 404-20}"

# Derive the "mcc-mnc" label from an IMS domain (ims.mnc020.mcc404... -> 404-20).
plmn_label_from_domain() {
    local dom="$1"
    local mnc mcc
    mnc=$(printf '%s' "$dom" | sed -nE 's/.*mnc([0-9]{2,3})\..*/\1/p')
    mcc=$(printf '%s' "$dom" | sed -nE 's/.*mcc([0-9]{3})\..*/\1/p')
    [ -z "$mnc" ] || [ -z "$mcc" ] && { echo ""; return 1; }
    # Strip a single leading zero from a 3-char MNC that is really 2 digits
    # (mnc020 -> 20) so the label matches the human "404-20" form.
    if [ ${#mnc} -eq 3 ] && [ "${mnc:0:1}" = "0" ]; then
        mnc="${mnc:1}"
    fi
    printf '%s-%s' "$mcc" "$mnc"
}

# Label of the PLMN currently under test (from IMS_DOMAIN).
ACTIVE_PLMN_LABEL="$(plmn_label_from_domain "$IMS_DOMAIN")"

# True if $1 (a "mcc-mnc" label) is in SUPPORTED_PLMNS.
plmn_is_supported() {
    local want="$1" p
    for p in $SUPPORTED_PLMNS; do
        [ "$p" = "$want" ] && return 0
    done
    return 1
}

# Phone-type User-Agent profiles. Both Optimus and Samsung retain Gm IPsec;
# these strings select only handset-specific SDP/session interop handling.
OPTIMUS_UA="${OPTIMUS_UA:-VoLTE/WFC UA}"
SAMSUNG_UA="${SAMSUNG_UA:-SAMSUNG-SM-G991B-Android13 Samsung IMS-client/6.0}"

# phone_ua PHONE  ->  the User-Agent string for that phone type.
phone_ua() {
    case "$1" in
        optimus|mtk|Optimus|MTK) echo "$OPTIMUS_UA" ;;
        samsung|Samsung)         echo "$SAMSUNG_UA" ;;
        *)                       echo "SIPp-Test-UA" ;;
    esac
}

# Docker host IP: where host-networked services (MMSC runs network_mode: host) and
# host-published ports are reachable from the test runner. Prefer an explicit value;
# otherwise auto-detect this container's default gateway (= the Docker host) so the
# suite is portable across hosts with no hardcoded lab IP.
if [ -z "${DOCKER_HOST_IP:-}" ]; then
    DOCKER_HOST_IP="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
fi
export DOCKER_HOST_IP

DNS_IP="${DNS_IP:-172.22.1.15}"
SMSC_IP="${SMSC_IP:-172.22.1.33}"
ICSCF_IP="${ICSCF_IP:-172.22.1.19}"
SCSCF_IP="${SCSCF_IP:-172.22.1.20}"
MYSQL_IP="${MYSQL_IP:-172.22.1.17}"
RTPENGINE_IP="${RTPENGINE_IP:-172.22.1.14}"
MMSC_IP="${MMSC_IP:-$DOCKER_HOST_IP}"
OSMOMSC_IP="${OSMOMSC_IP:-172.22.1.31}"
MME_IP="${MME_IP:-172.22.1.9}"
MME_PORT="${MME_PORT:-36412}"
SOFTPHONE_TARGET_URI="${SOFTPHONE_TARGET_URI:-}"
SOFTPHONE_TARGET_LABEL="${SOFTPHONE_TARGET_LABEL:-}"
SOFTPHONE_EXPECT_ANSWER="${SOFTPHONE_EXPECT_ANSWER:-true}"
SOFTPHONE_CALL_DURATION="${SOFTPHONE_CALL_DURATION:-5}"
PYHSS_API_KEY="${PYHSS_API_KEY:-}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-MySQL_PaSsW0rD}"
REPORT_DIR="/opt/test/reports"
UE_SIM_DIR="${UE_SIM_DIR:-/opt/test/ue_sim}"
DOCKER_HOST_LABEL="${DOCKER_HOST:-local/default}"
INCLUDE_TEST_CONTAINER_STATS="${INCLUDE_TEST_CONTAINER_STATS:-1}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
UE_SIM_PROBE_LOG="${UE_SIM_PROBE_LOG:-/tmp/ue_sim_probe.log}"
UE_SIM_PROBE_LAST_REASON=""
PROFILE_CONTAINERS="${PROFILE_CONTAINERS:-mme sgwc sgwu smf upf pyhss pcscf icscf scscf freeswitch mysql dns smsc mmsc}"
# Set VERBOSE_DIAG=1 to re-enable per-TC diagnostic report blocks for passing tests
VERBOSE_DIAG="${VERBOSE_DIAG:-0}"

# ============================================================
# Per-feature state
# ============================================================
_FEATURE_NAME=""
_FEATURE_PASS=0
_FEATURE_FAIL=0
_FEATURE_SKIP=0
_FEATURE_TOTAL=0
_FEATURE_REPORT=""
_FEATURE_START=""
_TEST_NUM=0
_SELECTED_TEST=0

# ============================================================
# Global state
# ============================================================
_GLOBAL_PASS=0
_GLOBAL_FAIL=0
_GLOBAL_SKIP=0
_GLOBAL_TOTAL=0
_START_TIME=""
_FEATURE_SUMMARIES=""
_FEATURE_REPORT_FILES=""
HW_PROBE_ENABLED="${HW_PROBE_ENABLED:-0}"
HW_SAMPLE_INTERVAL="${HW_SAMPLE_INTERVAL:-5}"
_HW_SAMPLE_FILE=""
_HW_HOST_FILE=""
_HW_CHECKPOINT_FILE=""
_HW_SAMPLER_PID=""

# ============================================================
# Initialize the test suite
# ============================================================
init_suite() {
    _START_TIME=$(date +%s)
    mkdir -p "$REPORT_DIR"
    _HW_SAMPLE_FILE="${REPORT_DIR}/hardware_samples.csv"
    _HW_HOST_FILE="${REPORT_DIR}/hardware_inventory.txt"
    _HW_CHECKPOINT_FILE="${REPORT_DIR}/hardware_checkpoints.csv"
    _GLOBAL_PASS=0
    _GLOBAL_FAIL=0
    _GLOBAL_SKIP=0
    _GLOBAL_TOTAL=0
    _FEATURE_SUMMARIES=""
    _FEATURE_REPORT_FILES=""

    init_hardware_probe
    capture_hardware_checkpoint "suite-start"
    log "Test suite initialized"
}

# ============================================================
# Start a feature
# ============================================================
start_feature() {
    local name="$1"
    _FEATURE_NAME="$name"
    _FEATURE_PASS=0
    _FEATURE_FAIL=0
    _FEATURE_SKIP=0
    _FEATURE_TOTAL=0
    _FEATURE_START=$(date '+%Y-%m-%d %H:%M:%S')
    _TEST_NUM=0

    local safe_name
    safe_name=$(echo "$name" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_')
    _FEATURE_REPORT="${REPORT_DIR}/${safe_name}.txt"
    if [ -z "$_FEATURE_REPORT_FILES" ]; then
        _FEATURE_REPORT_FILES="$_FEATURE_REPORT"
    else
        _FEATURE_REPORT_FILES="${_FEATURE_REPORT_FILES} ${_FEATURE_REPORT}"
    fi

    echo "============================================================" > "$_FEATURE_REPORT"
    echo "Feature: ${_FEATURE_NAME}" >> "$_FEATURE_REPORT"
    echo "Started: ${_FEATURE_START}" >> "$_FEATURE_REPORT"
    echo "============================================================" >> "$_FEATURE_REPORT"
    echo "" >> "$_FEATURE_REPORT"

    log "=========================================="
    log "Feature: ${_FEATURE_NAME}"
    log "=========================================="
}

# ============================================================
# Test result: PASS
# ============================================================
pass() {
    local description="$1"
    _FEATURE_PASS=$((_FEATURE_PASS + 1))
    _FEATURE_TOTAL=$((_FEATURE_TOTAL + 1))

    local line="[PASS] TC-${_TEST_NUM}: ${description}"
    echo "$line" >> "$_FEATURE_REPORT"
    log "$line"
}

# ============================================================
# Test result: FAIL
# ============================================================
fail() {
    local description="$1"
    local error_detail="$2"
    _FEATURE_FAIL=$((_FEATURE_FAIL + 1))
    _FEATURE_TOTAL=$((_FEATURE_TOTAL + 1))

    local line="[FAIL] TC-${_TEST_NUM}: ${description}"
    echo "$line" >> "$_FEATURE_REPORT"
    if [ -n "$error_detail" ]; then
        echo "       Error: ${error_detail}" >> "$_FEATURE_REPORT"
    fi
    log "$line"
    if [ -n "$error_detail" ]; then
        log "       Error: ${error_detail}"
    fi
}

# ============================================================
# Test result: SKIP
# ============================================================
skip() {
    local description="$1"
    local reason="$2"
    _FEATURE_SKIP=$((_FEATURE_SKIP + 1))
    _FEATURE_TOTAL=$((_FEATURE_TOTAL + 1))

    local line="[SKIP] TC-${_TEST_NUM}: ${description}"
    echo "$line" >> "$_FEATURE_REPORT"
    if [ -n "$reason" ]; then
        echo "       Reason: ${reason}" >> "$_FEATURE_REPORT"
    fi
    log "$line"
    if [ -n "$reason" ]; then
        log "       Reason: ${reason}"
    fi
}

# ============================================================
# End a feature
# ============================================================
end_feature() {
    echo "" >> "$_FEATURE_REPORT"
    echo "------------------------------------------------------------" >> "$_FEATURE_REPORT"
    echo "Results: ${_FEATURE_TOTAL} total, ${_FEATURE_PASS} passed, ${_FEATURE_FAIL} failed, ${_FEATURE_SKIP} skipped" >> "$_FEATURE_REPORT"
    echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')" >> "$_FEATURE_REPORT"
    echo "============================================================" >> "$_FEATURE_REPORT"

    # Accumulate into global counters
    _GLOBAL_PASS=$((_GLOBAL_PASS + _FEATURE_PASS))
    _GLOBAL_FAIL=$((_GLOBAL_FAIL + _FEATURE_FAIL))
    _GLOBAL_SKIP=$((_GLOBAL_SKIP + _FEATURE_SKIP))
    _GLOBAL_TOTAL=$((_GLOBAL_TOTAL + _FEATURE_TOTAL))

    # Build feature summary line for final report
    local summary_line
    summary_line=$(printf "%-25s %5d %5d %5d %5d" "$_FEATURE_NAME" "$_FEATURE_TOTAL" "$_FEATURE_PASS" "$_FEATURE_FAIL" "$_FEATURE_SKIP")
    if [ -z "$_FEATURE_SUMMARIES" ]; then
        _FEATURE_SUMMARIES="$summary_line"
    else
        _FEATURE_SUMMARIES="${_FEATURE_SUMMARIES}
${summary_line}"
    fi

    log "------------------------------------------"
    log "Feature '${_FEATURE_NAME}': ${_FEATURE_TOTAL} total, ${_FEATURE_PASS} passed, ${_FEATURE_FAIL} failed, ${_FEATURE_SKIP} skipped"
    log "------------------------------------------"
    log ""
    capture_hardware_checkpoint "${_FEATURE_NAME}"
}

# ============================================================
# Should this test run?
# Returns 0 (true) if _SELECTED_TEST==0 (run all) or matches test_num
# ============================================================
should_run_test() {
    local test_num="$1"
    if [ "$_SELECTED_TEST" -eq 0 ] || [ "$_SELECTED_TEST" -eq "$test_num" ]; then
        return 0
    fi
    return 1
}

# ============================================================
# Generate final summary report
# ============================================================
generate_summary() {
    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - _START_TIME ))
    local minutes=$(( duration / 60 ))
    local seconds=$(( duration % 60 ))

    local summary_file="${REPORT_DIR}/summary.txt"

    {
        echo "============================================================"
        echo "  Integration Test Suite - Summary Report"
        echo "  Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  Duration: ${minutes}m ${seconds}s"
        echo "============================================================"
        echo ""
        printf "%-25s %5s %5s %5s %5s\n" "Feature" "Total" "Pass" "Fail" "Skip"
        echo "---------------------------------------------------------------"
        echo "$_FEATURE_SUMMARIES"
        echo "---------------------------------------------------------------"
        printf "%-25s %5d %5d %5d %5d\n" "TOTAL" "$_GLOBAL_TOTAL" "$_GLOBAL_PASS" "$_GLOBAL_FAIL" "$_GLOBAL_SKIP"
        echo ""
        if [ "$_GLOBAL_FAIL" -eq 0 ] && [ "$_GLOBAL_SKIP" -eq 0 ]; then
            echo "Overall Result: ALL TESTS PASSED"
        elif [ "$_GLOBAL_FAIL" -eq 0 ]; then
            echo "Overall Result: NO FAILURES, BUT ${_GLOBAL_SKIP} TEST(S) SKIPPED"
        else
            echo "Overall Result: ${_GLOBAL_FAIL} TEST(S) FAILED"
        fi
        # Warn if too many tests were skipped (>20% of total)
        if [ "$_GLOBAL_TOTAL" -gt 0 ]; then
            local skip_pct=$(( _GLOBAL_SKIP * 100 / _GLOBAL_TOTAL ))
            if [ "$skip_pct" -gt 20 ]; then
                echo ""
                echo "WARNING: ${skip_pct}% of tests skipped (${_GLOBAL_SKIP}/${_GLOBAL_TOTAL})"
                echo "         Skipped tests do NOT count as failures."
                echo "         Review skipped tests to ensure coverage is adequate."
            fi
        fi
        # Warn if pass count is suspiciously low
        if [ "$_GLOBAL_PASS" -lt 10 ] && [ "$_GLOBAL_TOTAL" -gt 20 ]; then
            echo ""
            echo "WARNING: Only ${_GLOBAL_PASS} tests passed out of ${_GLOBAL_TOTAL} total."
            echo "         Most tests may be skipping due to missing dependencies."
        fi
        echo "============================================================"
    } > "$summary_file"

    log ""
    cat "$summary_file"
    log ""
    capture_hardware_checkpoint "suite-end"
    stop_hardware_probe
    generate_hardware_report
    generate_detailed_report
    log "Reports written to: ${REPORT_DIR}/"
}



# ============================================================
# Hardware and container resource probe
# ============================================================
init_hardware_probe() {
    {
        echo "4G EPC + IMS Hardware Inventory"
        echo "Captured: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "Host/VM"
        echo "======="
        echo "Kernel: $(uname -a 2>/dev/null || echo unknown)"
        echo "CPU cores available to test container: $(nproc 2>/dev/null || echo unknown)"
        if command -v lscpu >/dev/null 2>&1; then
            lscpu 2>/dev/null | sed 's/^/  /'
        fi
        echo ""
        echo "Memory"
        echo "======"
        if command -v free >/dev/null 2>&1; then
            free -h 2>/dev/null | sed 's/^/  /'
        else
            echo "  free command unavailable"
        fi
        echo ""
        echo "Storage"
        echo "======="
        df -h / 2>/dev/null | sed 's/^/  /'
        if command -v docker >/dev/null 2>&1; then
            local docker_root
            docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
            if [ -n "$docker_root" ]; then
                echo "Docker root: $docker_root"
                df -h "$docker_root" 2>/dev/null | sed 's/^/  /'
            fi
            echo ""
            echo "Docker storage summary"
            echo "======================"
            docker system df 2>/dev/null | sed 's/^/  /' || echo "  docker system df unavailable"
        else
            echo "Docker CLI unavailable; container-level resource checks disabled."
        fi
    } > "$_HW_HOST_FILE"

    echo "timestamp,feature,container,status,mem_current_bytes,mem_peak_bytes,cpu_usage_usec,cpu_user_usec,cpu_system_usec,io_read_bytes,io_write_bytes,pids" > "$_HW_CHECKPOINT_FILE"

    # Optional compatibility sampler. Exact cgroup checkpoints are always captured;
    # the sampler is only for approximate instantaneous CPU% peaks.
    if [ "${HW_PROBE_ENABLED:-0}" = "1" ]; then
        start_hardware_probe
    fi
}

read_container_cgroup_stats() {
    local container="$1"

    docker exec "$container" sh -c '
        read_first() { [ -r "$1" ] && head -n 1 "$1" 2>/dev/null || true; }

        mem_current=""
        mem_peak=""
        cpu_usage_usec=""
        cpu_user_usec=""
        cpu_system_usec=""
        io_read="0"
        io_write="0"
        pids=""

        if [ -r /sys/fs/cgroup/memory.current ]; then
            mem_current=$(read_first /sys/fs/cgroup/memory.current)
            mem_peak=$(read_first /sys/fs/cgroup/memory.peak)
        elif [ -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]; then
            mem_current=$(read_first /sys/fs/cgroup/memory/memory.usage_in_bytes)
            mem_peak=$(read_first /sys/fs/cgroup/memory/memory.max_usage_in_bytes)
        fi

        if [ -r /sys/fs/cgroup/cpu.stat ]; then
            cpu_usage_usec=$(awk "/^usage_usec / {print \$2}" /sys/fs/cgroup/cpu.stat 2>/dev/null)
            cpu_user_usec=$(awk "/^user_usec / {print \$2}" /sys/fs/cgroup/cpu.stat 2>/dev/null)
            cpu_system_usec=$(awk "/^system_usec / {print \$2}" /sys/fs/cgroup/cpu.stat 2>/dev/null)
        elif [ -r /sys/fs/cgroup/cpuacct/cpuacct.usage ]; then
            ns=$(read_first /sys/fs/cgroup/cpuacct/cpuacct.usage)
            cpu_usage_usec=$((ns / 1000))
        fi

        if [ -r /sys/fs/cgroup/io.stat ]; then
            set -- $(awk "{for(i=1;i<=NF;i++){split(\$i,a,\"=\"); if(a[1]==\"rbytes\") r+=a[2]; if(a[1]==\"wbytes\") w+=a[2]}} END{print r+0, w+0}" /sys/fs/cgroup/io.stat 2>/dev/null)
            io_read=${1:-0}
            io_write=${2:-0}
        elif [ -r /sys/fs/cgroup/blkio/blkio.throttle.io_service_bytes ]; then
            io_read=$(awk "$2==\"Read\" {r+=\$3} END{print r+0}" /sys/fs/cgroup/blkio/blkio.throttle.io_service_bytes 2>/dev/null)
            io_write=$(awk "$2==\"Write\" {w+=\$3} END{print w+0}" /sys/fs/cgroup/blkio/blkio.throttle.io_service_bytes 2>/dev/null)
        fi

        if [ -r /sys/fs/cgroup/pids.current ]; then
            pids=$(read_first /sys/fs/cgroup/pids.current)
        elif [ -r /sys/fs/cgroup/pids/pids.current ]; then
            pids=$(read_first /sys/fs/cgroup/pids/pids.current)
        fi

        printf "%s|%s|%s|%s|%s|%s|%s|%s\n" \
            "${mem_current:-}" "${mem_peak:-}" "${cpu_usage_usec:-}" \
            "${cpu_user_usec:-}" "${cpu_system_usec:-}" "${io_read:-0}" \
            "${io_write:-0}" "${pids:-}"
    ' 2>/dev/null
}

capture_hardware_checkpoint() {
    local feature="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    if ! command -v docker >/dev/null 2>&1; then
        return 0
    fi

    local container status stats mem_current mem_peak cpu_usage cpu_user cpu_system io_read io_write pids
    for container in $PROFILE_CONTAINERS; do
        status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo absent)
        if [ "$status" != "running" ]; then
            printf '%s,%s,%s,%s,,,,,,,,\n' "$ts" "$feature" "$container" "$status" >> "$_HW_CHECKPOINT_FILE"
            continue
        fi

        stats=$(read_container_cgroup_stats "$container")
        IFS='|' read -r mem_current mem_peak cpu_usage cpu_user cpu_system io_read io_write pids <<EOF_STATS
$stats
EOF_STATS
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$ts" "$feature" "$container" "$status" \
            "${mem_current:-}" "${mem_peak:-}" "${cpu_usage:-}" \
            "${cpu_user:-}" "${cpu_system:-}" "${io_read:-0}" "${io_write:-0}" "${pids:-}" \
            >> "$_HW_CHECKPOINT_FILE"
    done
}
stop_hardware_probe() {
    if [ -n "$_HW_SAMPLER_PID" ]; then
        kill "$_HW_SAMPLER_PID" 2>/dev/null || true
        wait "$_HW_SAMPLER_PID" 2>/dev/null || true
        _HW_SAMPLER_PID=""
    fi
}

start_hardware_probe() {
    [ "${HW_PROBE_ENABLED:-0}" = "1" ] || return 0

    echo "timestamp,name,cpu_percent,mem_usage,mem_percent,block_io,pids" > "$_HW_SAMPLE_FILE"

    {
        echo "4G EPC + IMS Hardware Inventory"
        echo "Captured: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "Host/VM"
        echo "======="
        echo "Kernel: $(uname -a 2>/dev/null || echo unknown)"
        echo "CPU cores available to test container: $(nproc 2>/dev/null || echo unknown)"
        if command -v lscpu >/dev/null 2>&1; then
            lscpu 2>/dev/null | sed 's/^/  /'
        fi
        echo ""
        echo "Memory"
        echo "======"
        if command -v free >/dev/null 2>&1; then
            free -h 2>/dev/null | sed 's/^/  /'
        else
            echo "  free command unavailable"
        fi
        echo ""
        echo "Storage"
        echo "======="
        df -h / 2>/dev/null | sed 's/^/  /'
        if command -v docker >/dev/null 2>&1; then
            local docker_root
            docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
            if [ -n "$docker_root" ]; then
                echo "Docker root: $docker_root"
                df -h "$docker_root" 2>/dev/null | sed 's/^/  /'
            fi
            echo ""
            echo "Docker storage summary"
            echo "======================"
            docker system df 2>/dev/null | sed 's/^/  /' || echo "  docker system df unavailable"
        else
            echo "Docker CLI unavailable; container-level resource sampling disabled."
        fi
    } > "$_HW_HOST_FILE"

    if ! command -v docker >/dev/null 2>&1; then
        return 0
    fi

    (
        while true; do
            local ts
            ts=$(date '+%Y-%m-%d %H:%M:%S')
            docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.BlockIO}},{{.PIDs}}' 2>/dev/null | \
            while IFS=',' read -r name cpu mem mempct block pids; do
                [ -n "$name" ] || continue
                printf '%s,%s,%s,%s,%s,%s,%s\n' "$ts" "$name" "$cpu" "$mem" "$mempct" "$block" "$pids"
            done
            sleep "${HW_SAMPLE_INTERVAL:-5}"
        done
    ) >> "$_HW_SAMPLE_FILE" &
    _HW_SAMPLER_PID=$!
    trap stop_hardware_probe EXIT
}

generate_hardware_report() {
    local hw_report="${REPORT_DIR}/hardware_resource_report.txt"
    local generated_at
    generated_at=$(date '+%Y-%m-%d %H:%M:%S')

    {
        echo "4G EPC + IMS Hardware and Resource Usage Report"
        echo "Generated: ${generated_at}"
        echo "Sample interval: ${HW_SAMPLE_INTERVAL:-5}s"
        echo ""
        if [ -f "$_HW_HOST_FILE" ]; then
            cat "$_HW_HOST_FILE"
        else
            echo "Hardware inventory was not captured."
        fi
        echo ""
        echo "Cgroup checkpoint resource report"
        echo "================================="
        if [ ! -s "$_HW_CHECKPOINT_FILE" ] || [ "$(wc -l < "$_HW_CHECKPOINT_FILE" 2>/dev/null || echo 0)" -le 1 ]; then
            echo "No cgroup checkpoint data was captured."
        else
            awk -F',' '
                function mib(bytes){ return bytes/1048576 }
                NR==1 { next }
                {
                    ts=$1; feature=$2; name=$3; status=$4
                    mem_current=$5+0; mem_peak=$6+0; cpu=$7+0; io_r=$10+0; io_w=$11+0; pids=$12+0
                    seen[name]=1
                    if (status == "running") running_seen[name]=1
                    if (mem_peak > max_mem_peak[name]) max_mem_peak[name]=mem_peak
                    if (mem_current > max_mem_current[name]) max_mem_current[name]=mem_current
                    if (io_r > max_io_r[name]) max_io_r[name]=io_r
                    if (io_w > max_io_w[name]) max_io_w[name]=io_w
                    if (pids > max_pids[name]) max_pids[name]=pids
                    if (!(name in first_cpu) && cpu > 0) first_cpu[name]=cpu
                    if (cpu > 0) last_cpu[name]=cpu
                    last_status[name]=status
                    last_ts[name]=ts

                    if ((name in prev_cpu) && cpu > 0 && prev_cpu[name] > 0 && feature != "suite-start") {
                        key=feature SUBSEP name
                        delta=cpu-prev_cpu[name]
                        if (delta < 0) delta=0
                        feature_cpu_delta[key]+=delta
                    }
                    if (cpu > 0) prev_cpu[name]=cpu
                    feature_seen[feature]=1
                }
                END {
                    print "Exact cgroup counters at feature boundaries:"
                    printf "%-24s %14s %14s %14s %14s %10s %10s\n", "Container", "MemPeakMiB", "MaxCurMiB", "CPUTimeSec", "IOWriteMiB", "IOReadMiB", "MaxPIDs"
                    print "------------------------------------------------------------------------------------------------"
                    for (name in seen) {
                        cpu_sec=(last_cpu[name]-first_cpu[name])/1000000
                        if (cpu_sec < 0) cpu_sec=0
                        printf "%-24s %14.1f %14.1f %14.1f %14.1f %10.1f %10d\n", name, mib(max_mem_peak[name]), mib(max_mem_current[name]), cpu_sec, mib(max_io_w[name]), mib(max_io_r[name]), max_pids[name]
                    }
                    print ""
                    print "Per-feature CPU time deltas (seconds, cumulative cgroup CPU time between checkpoints):"
                    printf "%-25s %-24s %12s\n", "Feature", "Container", "CPUTimeSec"
                    print "----------------------------------------------------------------"
                    for (key in feature_cpu_delta) {
                        split(key, parts, SUBSEP)
                        feature=parts[1]; name=parts[2]
                        delta=feature_cpu_delta[key]/1000000
                        if (delta > 0) printf "%-25s %-24s %12.2f\n", feature, name, delta
                    }
                    print ""
                    print "Notes:"
                    print "- MemPeakMiB uses cgroup memory.peak or memory.max_usage_in_bytes, so it is an OS-maintained peak, not a sample."
                    print "- CPUTimeSec is exact cumulative CPU time delta. Linux does not keep exact historical max CPU%, so instantaneous CPU peak still requires sampling."
                    print "- I/O counters are cumulative cgroup bytes where exposed by the kernel."
                }
            ' "$_HW_CHECKPOINT_FILE"
        fi
        echo ""
        echo "Optional sampled Docker stats"
        echo "============================="
        if [ ! -s "$_HW_SAMPLE_FILE" ] || [ "$(wc -l < "$_HW_SAMPLE_FILE" 2>/dev/null || echo 0)" -le 1 ]; then
            if [ "${HW_PROBE_ENABLED:-0}" = "1" ]; then
                echo "No Docker stats samples were captured."
                echo "Possible reasons: Docker CLI unavailable inside the test container, permission denied, or the suite ended before the first sample."
            else
                echo "Docker stats sampling is disabled by default. Enable HW_PROBE_ENABLED=1 for approximate instantaneous CPU% peaks."
            fi
        else
            awk -F',' '
                function trim(s){gsub(/^[ \t]+|[ \t]+$/, "", s); return s}
                function to_mib(v, n, u){
                    v=trim(v)
                    if (v == "" || v == "-") return 0
                    n=v+0
                    u=v
                    sub(/^[0-9.]+[ \t]*/, "", u)
                    if (u ~ /^KiB$/) return n/1024
                    if (u ~ /^MiB$/) return n
                    if (u ~ /^GiB$/) return n*1024
                    if (u ~ /^TiB$/) return n*1024*1024
                    if (u ~ /^kB$/) return n/1024
                    if (u ~ /^MB$/) return n*1000000/1048576
                    if (u ~ /^GB$/) return n*1000000000/1048576
                    if (u ~ /^B$/) return n/1048576
                    return n
                }
                NR==1 { next }
                {
                    name=$2
                    cpu=$3; gsub(/%/, "", cpu); cpu+=0
                    split($4, memparts, "/")
                    mem_mib=to_mib(memparts[1])
                    split($6, blockparts, "/")
                    blk_read_mib=to_mib(blockparts[1])
                    blk_write_mib=to_mib(blockparts[2])
                    pids=$7+0

                    seen[name]=1
                    if (cpu > max_cpu[name]) max_cpu[name]=cpu
                    if (mem_mib > max_mem[name]) max_mem[name]=mem_mib
                    if (blk_read_mib > max_blk_read[name]) max_blk_read[name]=blk_read_mib
                    if (blk_write_mib > max_blk_write[name]) max_blk_write[name]=blk_write_mib
                    if (pids > max_pids[name]) max_pids[name]=pids

                    sample_cpu[$1] += cpu
                    sample_mem[$1] += mem_mib
                    if (sample_cpu[$1] > total_cpu_peak) { total_cpu_peak=sample_cpu[$1]; total_cpu_ts=$1 }
                    if (sample_mem[$1] > total_mem_peak) { total_mem_peak=sample_mem[$1]; total_mem_ts=$1 }
                }
                END {
                    printf "Peak total container CPU: %.2f%% (%.2f core-equivalent) at %s\n", total_cpu_peak, total_cpu_peak/100, total_cpu_ts
                    printf "Peak total container RAM: %.1f MiB (%.2f GiB) at %s\n", total_mem_peak, total_mem_peak/1024, total_mem_ts
                    print ""
                    printf "%-24s %12s %14s %14s %14s %8s\n", "Container", "MaxCPU%", "MaxRAMMiB", "BlkReadMiB", "BlkWriteMiB", "MaxPIDs"
                    print "--------------------------------------------------------------------------------------"
                    for (name in seen) {
                        printf "%-24s %12.2f %14.1f %14.1f %14.1f %8d\n", name, max_cpu[name], max_mem[name], max_blk_read[name], max_blk_write[name], max_pids[name]
                    }
                    print ""
                    print "Notes:"
                    print "- MaxCPU% is Docker CPU percent; 100% roughly equals one fully used CPU core."
                    print "- Core-equivalent usage is total Docker CPU percent divided by 100."
                    print "- MaxRAMMiB is observed resident container memory, not configured memory limit."
                    print "- Block I/O is cumulative container block read/write observed by Docker, used here as storage activity evidence."
                    print "- Disk capacity and Docker image/volume usage are listed in the hardware inventory above."
                }
            ' "$_HW_SAMPLE_FILE"
        fi
        echo ""
        echo "Limitations"
        echo "==========="
        echo "- Memory peak is read from OS/cgroup peak counters when available, so it is not limited by sample interval."
        echo "- Linux cgroups expose cumulative CPU time, not exact historical peak CPU%; exact CPU peak still requires active sampling or an external monitor."
        echo "- ROM is interpreted as storage/disk usage: filesystem capacity plus Docker image/container/volume usage where available."
        echo "- RAM peak is container cgroup memory peak; host page cache and kernel memory are not fully attributed to containers."
        echo "- Optional docker-stats sampling can be enabled with HW_PROBE_ENABLED=1 when approximate instantaneous CPU% peaks are needed."
    } > "$hw_report"

    log "Hardware/resource report written to: ${hw_report}"
}

# ============================================================
# Generate detailed automatic report from per-feature reports
# ============================================================
explain_test_meaning() {
    local feature="$1"
    local status="$2"
    local description="$3"
    local detail="$4"
    local lc_feature lc_desc lc_detail combined

    lc_feature=$(printf '%s' "$feature" | tr '[:upper:]' '[:lower:]')
    lc_desc=$(printf '%s' "$description" | tr '[:upper:]' '[:lower:]')
    lc_detail=$(printf '%s' "$detail" | tr '[:upper:]' '[:lower:]')
    combined="${lc_feature} ${lc_desc} ${lc_detail}"

    if [ "$status" = "PASS" ]; then
        case "$combined" in
            *"container"*"running"*|*"container health"*)
                echo "    Meaning: required containers are running and not obviously crash-looping."
                ;;
            *"diameter"*|*"s6a"*|*"cx"*|*"rx"*)
                echo "    Meaning: Diameter control-plane peers and request paths are reachable."
                ;;
            *"attach"*"register"*|*"ims register"*)
                echo "    Meaning: UE attach and IMS SIP registration are working end-to-end."
                ;;
            *"volte"*"call"*|*"invite"*"bye"*|*"call"*"completed"*)
                echo "    Meaning: VoLTE call setup, answer, and teardown succeeded."
                ;;
            *"vilte"*|*"video"*)
                echo "    Meaning: video-call signaling/media policy support is configured and validated."
                ;;
            *"conference"*)
                echo "    Meaning: the tested conference path is working for the configured dialplan/routing."
                ;;
            *"cdr"*)
                echo "    Meaning: call detail records are being written and basic CDR structure is valid."
                ;;
            *"qci"*|*"bearer"*|*"qos"*)
                echo "    Meaning: EPC/IMS bearer and QoS behavior matched the expected QCI path."
                ;;
            *"dns"*)
                echo "    Meaning: DNS records required for IMS routing are resolvable."
                ;;
            *"mysql"*|*"database"*)
                echo "    Meaning: database access and required schema/data checks succeeded."
                ;;
            *"throughput"*|*"capacity"*|*"jitter"*|*"load"*)
                echo "    Meaning: the measured capacity/performance point met the suite threshold."
                ;;
            *)
                echo "    Meaning: this validation point passed for the current deployment and test inputs."
                ;;
        esac
        return
    fi

    if [ "$status" = "SKIP" ]; then
        case "$combined" in
            *"conf-factory"*|*"conference factory"*)
                echo "    Why: conference-factory DNS/routing is not configured in this deployment."
                echo "    To enable: add conf-factory DNS, P-CSCF/S-CSCF routing, and matching FreeSWITCH dialplan support."
                ;;
            *"call merge"*|*"3-way merge"*)
                echo "    Why: call-merge coverage is intentionally not ported/enabled in this BuildTestSuite version."
                echo "    To enable: implement the intended production call-merge path and re-enable the UE/test scenario."
                ;;
            *"fxo"*|*"fxs"*)
                echo "    Why: FXO/FXS production call path is not confirmed or enabled."
                echo "    To enable: define the gateway topology, dialplan, routing, and assertions for external line breakout."
                ;;
            *"softphone"*|*"mobile-to-ip"*|*"softphone_target_uri"*)
                echo "    Why: no same-IMS softphone target is configured."
                echo "    To enable: register a softphone/SIP endpoint and set SOFTPHONE_TARGET_URI for the suite."
                ;;
            *"mmsc"*|*"mms"*|*"kannel"*|*"mbuni"*)
                echo "    Why: the optional MMSC/MMS stack is not running in the default deployment."
                echo "    To enable: start MMSC and verify Kannel, Mbuni, MM7, SMPP, storage, and notification-SMS paths."
                ;;
            *)
                echo "    Why: ${detail:-the test declared its prerequisite unavailable.}"
                echo "    To enable: satisfy the skipped test prerequisite and rerun this feature."
                ;;
        esac
        return
    fi

    case "$combined" in
        *"burst attach"*|*"attach burst"*)
            echo "    Issue: burst attach capacity is below the suite threshold for the measured scenario."
            echo "    Likely cause: MME NAS/freeDiameter queueing, PyHSS/MySQL Diameter pressure, zero-stagger attach bursts, or post-load EPC residue."
            echo "    To address: tune MME/PyHSS/MySQL concurrency, investigate SMF exits under load, consider attach staggering or SCTP multi-streaming, then rerun Load Test."
            ;;
        *"freeswitch"*)
            echo "    Issue: FreeSWITCH health, SIP profile, ACL, or dialplan behavior did not match expectations."
            echo "    To address: check FreeSWITCH container state, fs_cli access, Sofia profiles, ACLs, and matching dialplan routes."
            ;;
        *"diameter"*|*"s6a"*|*"cx"*|*"rx"*)
            echo "    Issue: Diameter peer connectivity or transaction behavior failed."
            echo "    To address: check peer state, realm/host config, freeDiameter logs, PyHSS/PCRF reachability, and timeout/worker sizing."
            ;;
        *"attach"*|*"register"*)
            echo "    Issue: EPC attach or IMS registration failed."
            echo "    To address: inspect MME, PyHSS, P-CSCF/I-CSCF/S-CSCF logs, subscriber credentials, SQN/AUC mapping, and DNS routing."
            ;;
        *"call"*|*"invite"*|*"bye"*)
            echo "    Issue: SIP call setup, answer, media policy, or teardown failed."
            echo "    To address: inspect SIP route logs, UE simulator output, P-CSCF/S-CSCF dialogs, FreeSWITCH behavior, and RTPengine/Rx traces."
            ;;
        *"mmsc"*|*"mms"*)
            echo "    Issue: MMS component or path failed."
            echo "    To address: verify MMSC/Kannel/Mbuni containers, ports, storage, and notification path."
            ;;
        *)
            echo "    Issue: ${detail:-the test assertion failed.}"
            echo "    To address: inspect the feature report and container logs for this test case, fix the failed prerequisite/path, and rerun."
            ;;
    esac
}

append_core_limitations() {
    cat <<'EOF'
Core/EPC/IMS limitations observed or measured
=============================================
- Load capacity is bounded by the current VM/container resources and host networking behavior; results are deployment-local, not universal product limits.
- Zero-stagger attach bursts are intentionally harsh and can expose MME NAS/freeDiameter queueing, PyHSS Diameter/MySQL pressure, and SMF recovery behavior.
- Current measured burst/capacity numbers should be treated as baseline capacity evidence, not final production sizing.
- P-CSCF IPSec validation is limited when UE simulators do not establish real IPSec tunnels; the suite checks configuration/headroom and non-IPSec SIP paths.
- RTPEngine checks may rely on container/process/module evidence when NG control ping is not reachable from the test container because RTPEngine runs on host networking.
- MMS, FXO/FXS, Mobile-to-IP, and conf-factory are optional or environment-dependent paths unless explicitly enabled in the deployment.
- Direct FreeSWITCH conference dial-in is validated separately from conf-factory/call-merge routing.
- Long-duration call validation is a smoke test, not a full multi-hour soak unless the stress duration is increased.

Test suite limitations
======================
- PASS means the configured scenario passed in this test environment; it does not prove every production topology or traffic mix.
- SKIP means a prerequisite, optional component, or intentionally unported feature is missing; skipped tests are coverage gaps, not runtime failures.
- Load tests use synthetic UE/SIPp behavior and may not model every handset, radio, NAT, codec, IPSec, or RF condition.
- Some throughput tests validate tunnel reachability and captured metrics opportunistically; host/container networking can make iperf directionality or captured receive rates imperfect.
- Feature-only runs generate a report for only the features that ran; use --bundle all for release-level coverage reporting.
- The generated explanations are rule-based from test names and error/reason lines; detailed root cause still requires logs when a test fails.
- Optional feature tests should be enabled one area at a time so failures are attributable to a specific newly enabled path.
EOF
}

append_hardware_spec_summary() {
    echo "Hardware used for this run"
    echo "=========================="
    if [ ! -f "$_HW_HOST_FILE" ]; then
        echo "Hardware inventory was not captured."
        return 0
    fi

    local kernel cores model cpu_count threads cores_per_socket sockets mem_line root_df docker_root docker_df
    kernel=$(sed -n 's/^Kernel: //p' "$_HW_HOST_FILE" | head -1)
    cores=$(sed -n 's/^CPU cores available to test container: //p' "$_HW_HOST_FILE" | head -1)
    model=$(sed -n 's/^  Model name:[[:space:]]*//p' "$_HW_HOST_FILE" | head -1)
    cpu_count=$(sed -n 's/^  CPU(s):[[:space:]]*//p' "$_HW_HOST_FILE" | head -1)
    threads=$(sed -n 's/^  Thread(s) per core:[[:space:]]*//p' "$_HW_HOST_FILE" | head -1)
    cores_per_socket=$(sed -n 's/^  Core(s) per socket:[[:space:]]*//p' "$_HW_HOST_FILE" | head -1)
    sockets=$(sed -n 's/^  Socket(s):[[:space:]]*//p' "$_HW_HOST_FILE" | head -1)
    mem_line=$(awk '/^  Mem:/ {print; exit}' "$_HW_HOST_FILE")
    root_df=$(awk '/^  Filesystem/ {getline; print; exit}' "$_HW_HOST_FILE")
    docker_root=$(sed -n 's/^Docker root: //p' "$_HW_HOST_FILE" | head -1)
    docker_df=$(awk '
        /^Docker root:/ { in_docker=1; next }
        in_docker && /^  Filesystem/ { getline; print; exit }
    ' "$_HW_HOST_FILE")

    [ -n "$kernel" ] && echo "Kernel: ${kernel}"
    [ -n "$model" ] && echo "CPU model: ${model}"
    [ -n "$cores" ] && echo "CPU cores visible to test container: ${cores}"
    [ -n "$cpu_count" ] && echo "Host CPU(s): ${cpu_count}"
    [ -n "$threads" ] && echo "Threads per core: ${threads}"
    [ -n "$cores_per_socket" ] && echo "Cores per socket: ${cores_per_socket}"
    [ -n "$sockets" ] && echo "Sockets: ${sockets}"
    [ -n "$mem_line" ] && echo "RAM: ${mem_line#  }"
    [ -n "$root_df" ] && echo "Root filesystem: ${root_df#  }"
    [ -n "$docker_root" ] && echo "Docker root: ${docker_root}"
    [ -n "$docker_df" ] && echo "Docker filesystem: ${docker_df#  }"
    echo "Detailed hardware/resource report: ${REPORT_DIR}/hardware_resource_report.txt"
}

generate_detailed_report() {
    local detailed_file="${REPORT_DIR}/detailed_test_report.txt"
    local generated_at
    generated_at=$(date '+%Y-%m-%d %H:%M:%S')

    {
        echo "4G EPC + IMS Integration Suite"
        echo "Detailed Automatic Test Report"
        echo "Generated: ${generated_at}"
        echo "Reports directory: ${REPORT_DIR}"
        echo ""
        append_hardware_spec_summary
        echo ""
        echo "Executive summary"
        echo "================="
        echo "Total tests: ${_GLOBAL_TOTAL}"
        echo "Passed:      ${_GLOBAL_PASS}"
        echo "Failed:      ${_GLOBAL_FAIL}"
        echo "Skipped:     ${_GLOBAL_SKIP}"
        echo ""
        if [ "$_GLOBAL_FAIL" -eq 0 ] && [ "$_GLOBAL_SKIP" -eq 0 ]; then
            echo "Overall assessment: all executed coverage passed and no tests were skipped."
        elif [ "$_GLOBAL_FAIL" -eq 0 ]; then
            echo "Overall assessment: no runtime failures, but skipped tests remain as coverage gaps."
        else
            echo "Overall assessment: runtime failures require attention before the suite is fully green."
        fi
        echo ""
        echo "Feature summary"
        echo "==============="
        printf "%-25s %5s %5s %5s %5s\n" "Feature" "Total" "Pass" "Fail" "Skip"
        echo "---------------------------------------------------------------"
        echo "$_FEATURE_SUMMARIES"
        echo "---------------------------------------------------------------"
        printf "%-25s %5d %5d %5d %5d\n" "TOTAL" "$_GLOBAL_TOTAL" "$_GLOBAL_PASS" "$_GLOBAL_FAIL" "$_GLOBAL_SKIP"
        echo ""
        echo "What is working fine"
        echo "===================="
        if [ "$_GLOBAL_PASS" -eq 0 ]; then
            echo "No passed tests were recorded in this run."
        else
            local report_file feature line status tc desc detail next
            for report_file in $_FEATURE_REPORT_FILES; do
                [ -f "$report_file" ] || continue
                case "$(basename "$report_file")" in
                    summary.txt|detailed_test_report.txt|SKIPPED_AND_FAILING_TEST_REPORT.txt) continue ;;
                esac
                feature=$(sed -n 's/^Feature: //p' "$report_file" | head -1)
                [ -n "$feature" ] || feature="$(basename "$report_file" .txt)"
                while IFS= read -r line; do
                    case "$line" in
                        "[PASS] TC-"*)
                            tc=$(printf '%s' "$line" | sed -n 's/^\[PASS\] \(TC-[0-9][0-9]*\): .*/\1/p')
                            desc=$(printf '%s' "$line" | sed -n 's/^\[PASS\] TC-[0-9][0-9]*: //p')
                            echo "- ${feature} ${tc}: ${desc}"
                            explain_test_meaning "$feature" "PASS" "$desc" ""
                            ;;
                    esac
                done < "$report_file"
            done
        fi
        echo ""
        echo "Failed test cases"
        echo "================="
        if [ "$_GLOBAL_FAIL" -eq 0 ]; then
            echo "No failed tests recorded."
        else
            local report_file feature line tc desc err
            for report_file in $_FEATURE_REPORT_FILES; do
                [ -f "$report_file" ] || continue
                case "$(basename "$report_file")" in
                    summary.txt|detailed_test_report.txt|SKIPPED_AND_FAILING_TEST_REPORT.txt) continue ;;
                esac
                feature=$(sed -n 's/^Feature: //p' "$report_file" | head -1)
                [ -n "$feature" ] || feature="$(basename "$report_file" .txt)"
                while IFS= read -r line; do
                    case "$line" in
                        "[FAIL] TC-"*)
                            tc=$(printf '%s' "$line" | sed -n 's/^\[FAIL\] \(TC-[0-9][0-9]*\): .*/\1/p')
                            desc=$(printf '%s' "$line" | sed -n 's/^\[FAIL\] TC-[0-9][0-9]*: //p')
                            IFS= read -r err || err=""
                            case "$err" in
                                "       Error:"*) ;;
                                *) err="" ;;
                            esac
                            err=${err#       Error: }
                            echo "- ${feature} ${tc}: ${desc}"
                            [ -n "$err" ] && echo "    Error: ${err}"
                            explain_test_meaning "$feature" "FAIL" "$desc" "$err"
                            ;;
                    esac
                done < "$report_file"
            done
        fi
        echo ""
        echo "Skipped test cases"
        echo "=================="
        if [ "$_GLOBAL_SKIP" -eq 0 ]; then
            echo "No skipped tests recorded."
        else
            local report_file feature line tc desc reason
            for report_file in $_FEATURE_REPORT_FILES; do
                [ -f "$report_file" ] || continue
                case "$(basename "$report_file")" in
                    summary.txt|detailed_test_report.txt|SKIPPED_AND_FAILING_TEST_REPORT.txt) continue ;;
                esac
                feature=$(sed -n 's/^Feature: //p' "$report_file" | head -1)
                [ -n "$feature" ] || feature="$(basename "$report_file" .txt)"
                while IFS= read -r line; do
                    case "$line" in
                        "[SKIP] TC-"*)
                            tc=$(printf '%s' "$line" | sed -n 's/^\[SKIP\] \(TC-[0-9][0-9]*\): .*/\1/p')
                            desc=$(printf '%s' "$line" | sed -n 's/^\[SKIP\] TC-[0-9][0-9]*: //p')
                            IFS= read -r reason || reason=""
                            case "$reason" in
                                "       Reason:"*) ;;
                                *) reason="" ;;
                            esac
                            reason=${reason#       Reason: }
                            echo "- ${feature} ${tc}: ${desc}"
                            [ -n "$reason" ] && echo "    Reason: ${reason}"
                            explain_test_meaning "$feature" "SKIP" "$desc" "$reason"
                            ;;
                    esac
                done < "$report_file"
            done
        fi
        echo ""
        if [ -f "${REPORT_DIR}/tec_certification_gap_matrix.txt" ]; then
            echo "TEC readiness matrix"
            echo "===================="
            cat "${REPORT_DIR}/tec_certification_gap_matrix.txt"
            echo ""
        fi
        append_core_limitations
        echo ""
        echo "Recommended next actions"
        echo "========================"
        if [ "$_GLOBAL_FAIL" -gt 0 ]; then
            echo "1. Fix failed tests first; they represent active runtime or threshold failures."
        else
            echo "1. No failed tests were recorded; focus on skipped coverage and capacity tuning."
        fi
        if [ "$_GLOBAL_SKIP" -gt 0 ]; then
            echo "2. Review skipped tests and decide which optional features are release requirements."
            echo "3. Enable skipped feature prerequisites one at a time, then rerun the affected feature."
        else
            echo "2. Keep the generated report with the run artifacts for release evidence."
        fi
        echo "4. Treat load/capacity numbers as baselines; tune and rerun before using them for production sizing."
    } > "$detailed_file"

    log "Detailed report written to: ${detailed_file}"
}

# ============================================================
# Helper: wait for service to become available
# ============================================================
wait_for_service() {
    local host="$1"
    local port="$2"
    local timeout_secs="$3"
    local service_name="$4"

    log "Waiting for ${service_name} at ${host}:${port} (timeout: ${timeout_secs}s)..."

    local elapsed=0
    while [ "$elapsed" -lt "$timeout_secs" ]; do
        if nc -z -w 2 "$host" "$port" 2>/dev/null; then
            log "${service_name} is available at ${host}:${port}"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    log "Timeout waiting for ${service_name} at ${host}:${port} after ${timeout_secs}s"
    return 1
}

# ============================================================
# Helper: check DNS A record
# ============================================================
check_dns_a() {
    local fqdn="$1"
    local expected_ip="$2"

    local result
    result=$(dig +short "$fqdn" @"$DNS_IP" A 2>/dev/null | head -1 | tr -d '[:space:]')

    if [ "$result" = "$expected_ip" ]; then
        return 0
    fi
    return 1
}

# ============================================================
# Helper: check DNS SRV record
# ============================================================
check_dns_srv() {
    local fqdn="$1"
    local expected_port="$2"

    local result
    result=$(dig +short SRV "$fqdn" @"$DNS_IP" 2>/dev/null)

    if echo "$result" | grep -q "$expected_port"; then
        return 0
    fi
    return 1
}

# ============================================================
# Helper: check port open
# ============================================================
check_port() {
    local host="$1"
    local port="$2"

    nc -z -w 2 "$host" "$port" 2>/dev/null
    return $?
}

# ============================================================
# Helper: check if a Docker container is running
# Only an exit-0 'docker ps' listing is a definitive answer.
# Right after 'docker compose up -d' brings up the full stack,
# dockerd can answer slowly enough that the 8s timeout fires;
# that must not be reported as "not running", so timeout/error
# is retried briefly.  A clean listing that lacks the name
# returns immediately (no retries).
# ============================================================
container_is_running() {
    local name="$1"
    local attempt names rc
    for attempt in 1 2 3; do
        names=$(timeout 8 docker ps --format '{{.Names}}' 2>/dev/null)
        rc=$?
        if [ "$rc" -eq 0 ]; then
            printf '%s\n' "$names" | grep -qx "$name"
            return $?
        fi
        [ "$attempt" -lt 3 ] && sleep 4
    done
    return 1
}

# ============================================================
# Helper: check if a container is listening on a port internally
# Works for SCTP listeners like MME S1AP as well.
# rc 124 (timeout) and rc 125 (docker daemon error) mean dockerd
# was slow/unavailable, not that the listener is absent — retry
# those briefly.  Any other result (socket listing without the
# port, container not running, no ss/netstat in the image) is
# definitive and returns immediately.
# ============================================================
container_listens_on_port() {
    local container="$1"
    local port="$2"
    local attempt sockets rc

    for attempt in 1 2 3; do
        sockets=$(timeout 8 docker exec "$container" sh -c "
            if command -v ss >/dev/null 2>&1; then
                ss -H -ln 2>/dev/null
            elif command -v netstat >/dev/null 2>&1; then
                netstat -ln 2>/dev/null
            else
                exit 1
            fi
        " 2>/dev/null)
        rc=$?
        if [ "$rc" -eq 0 ]; then
            printf '%s\n' "$sockets" | grep -Eq "[:.]${port}([[:space:]]|$)"
            return $?
        fi
        if [ "$rc" -ne 124 ] && [ "$rc" -ne 125 ]; then
            return 1
        fi
        [ "$attempt" -lt 3 ] && sleep 4
    done
    return 1
}

# ============================================================
# Helper: check whether MME S1AP is actually ready
# ============================================================
mme_s1ap_ready() {
    container_is_running "mme" || return 1
    container_listens_on_port "mme" 36412 || return 1
    return 0
}

# ============================================================
# Helper: probe EPC end-to-end by attempting a real UE attach.
#
# S1AP port becoming available does NOT mean S6a Diameter is
# ready — open5gs MME accepts S1AP connections before the S6a
# Diameter re-association with PyHSS is complete.  If the MME
# hasn't finished its S6a CEA handshake, AIR → AuthenticationReq
# fails and the UE attach returns False immediately.  PFCP
# association between SMF and UPF is subject to the same gap.
#
# This probe retries a real UE attach (not just a port check)
# so it catches both S6a and PFCP readiness in one shot.
#
# Args:
#   $1 label        — prefix for log lines  (default "EPC probe")
#   $2 max_attempts — number of retries      (default 5)
#   $3 retry_sleep  — seconds between retries (default 5)
#
# Returns 0 on the first successful attach, 1 after all retries.
# ============================================================
mme_epc_probe() {
    local label="${1:-EPC probe}"
    local max_attempts="${2:-5}"
    local retry_sleep="${3:-5}"

    local _attempt=0
    while [ $_attempt -lt "$max_attempts" ]; do
        local _result
        _result=$(timeout 20 "$PYTHON_BIN" -c "
import sys, json, os
sys.path.insert(0, '/opt/test')
os.environ.setdefault('MME_IP',   '${MME_IP:-172.22.1.9}')
os.environ.setdefault('PCSCF_IP', '${PCSCF_IP:-172.22.1.21}')
os.environ.setdefault('LOCAL_IP', '${LOCAL_IP:-172.22.1.200}')
os.environ.setdefault('MCC', '${MCC:-001}')
os.environ.setdefault('MNC', '${MNC:-01}')
from ue_sim.ue_simulator import UESimulator
from ue_sim.config import Config
import logging
logging.disable(logging.WARNING)
sub = Config.default_subscribers()[0]
ue = UESimulator(imsi=sub.imsi, ki=sub.ki, opc=sub.opc, msisdn=sub.msisdn)
ok = ue.attach()
ue.detach()
print(json.dumps({'ok': ok}))
" 2>/dev/null || echo '{"ok":false}')

        local _ok
        _ok=$(echo "$_result" | "$PYTHON_BIN" -c \
            "import sys,json; print(json.load(sys.stdin).get('ok',False))" 2>/dev/null \
            || echo "False")

        _attempt=$((_attempt + 1))
        if [ "$_ok" = "True" ]; then
            log "  ${label}: PASS (attempt ${_attempt} — S6a+PFCP ready)"
            return 0
        fi

        if [ $_attempt -lt "$max_attempts" ]; then
            log "  ${label}: attach FAIL (attempt ${_attempt}), waiting ${retry_sleep}s for S6a/PFCP..."
            sleep "$retry_sleep"
        else
            log "  ${label}: WARNING — attach still failing after ${max_attempts} attempts; tests may fail"
        fi
    done
    return 1
}

# ============================================================
# Helper: verify the Python UE simulator environment end-to-end
# ============================================================
ue_sim_probe() {
    UE_SIM_PROBE_LAST_REASON=""
    rm -f "$UE_SIM_PROBE_LOG" 2>/dev/null

    if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
        UE_SIM_PROBE_LAST_REASON="${PYTHON_BIN} not installed in test container"
        return 1
    fi

    if [ ! -d "$UE_SIM_DIR" ]; then
        UE_SIM_PROBE_LAST_REASON="UE simulator files missing at ${UE_SIM_DIR}"
        return 1
    fi

    if ! "$PYTHON_BIN" - >/tmp/ue_sim_probe.out 2>"$UE_SIM_PROBE_LOG" <<'PY'
import sys

sys.path.insert(0, "/opt/test")

from ue_sim.config import Config
from ue_sim.milenage import Milenage
from ue_sim.s1ap_client import S1APClient, SharedS1APConnection
from ue_sim.sip_client import SIPClient
from ue_sim.ue_simulator import UESimulator, run_enb_capacity_test, run_load_test

subs = Config.default_subscribers()
assert len(subs) >= 3
assert callable(run_enb_capacity_test)
assert callable(run_load_test)
assert Milenage is not None
assert S1APClient is not None
assert SharedS1APConnection is not None
assert SIPClient is not None
assert UESimulator is not None

print("OK")
PY
    then
        if [ -s "$UE_SIM_PROBE_LOG" ]; then
            UE_SIM_PROBE_LAST_REASON=$(tail -3 "$UE_SIM_PROBE_LOG" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
        fi
        [ -n "$UE_SIM_PROBE_LAST_REASON" ] || UE_SIM_PROBE_LAST_REASON="Python UE simulator import failed"
        return 1
    fi

    if ! grep -qx "OK" /tmp/ue_sim_probe.out 2>/dev/null; then
        UE_SIM_PROBE_LAST_REASON="Python UE simulator probe completed without OK marker"
        return 1
    fi

    return 0
}

# ============================================================
# Helper: summarize last UE simulator probe failure
# ============================================================
ue_sim_probe_reason() {
    if [ -n "$UE_SIM_PROBE_LAST_REASON" ]; then
        echo "$UE_SIM_PROBE_LAST_REASON"
    elif [ -s "$UE_SIM_PROBE_LOG" ]; then
        tail -3 "$UE_SIM_PROBE_LOG" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
    else
        echo "unknown Python UE simulator error"
    fi
}

# ============================================================
# Helper: curl JSON API - GET (honours PYHSS_API_KEY if set)
# ============================================================
api_get() {
    local url="$1"
    if [ -n "$PYHSS_API_KEY" ]; then
        curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${PYHSS_API_KEY}" "$url" 2>/dev/null
    else
        curl -s -w "\n%{http_code}" "$url" 2>/dev/null
    fi
}

# ============================================================
# Helper: curl JSON API - PUT (honours PYHSS_API_KEY if set)
# ============================================================
api_put() {
    local url="$1"
    local json_body="$2"
    if [ -n "$PYHSS_API_KEY" ]; then
        curl -s -w "\n%{http_code}" -X PUT \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${PYHSS_API_KEY}" \
            -d "$json_body" "$url" 2>/dev/null
    else
        curl -s -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" -d "$json_body" "$url" 2>/dev/null
    fi
}

# ============================================================
# Helper: docker exec on another container
# ============================================================
docker_exec() {
    local container_name="$1"
    local command="$2"
    docker exec "$container_name" bash -c "$command" 2>&1
}

# ============================================================
# Helper: read an Open5GS NF YAML config (TRL8 conformance/assurance)
# Tries the volume-mount path first, then the in-image install path.
# Adding this function is additive and does not affect existing tests.
# Usage: cfg=$(read_nf_config mme)
# ============================================================
read_nf_config() {
    local nf="$1"
    docker exec "$nf" sh -c "cat /mnt/${nf}/${nf}.yaml 2>/dev/null || cat /open5gs/install/etc/open5gs/${nf}.yaml 2>/dev/null" 2>/dev/null || true
}

# ============================================================
# Helper: numeric UID a container runs as (TRL8/SCAS hardening)
# Echoes the uid (0 = root), or empty if undeterminable. Additive.
# ============================================================
container_uid() {
    docker exec "$1" id -u 2>/dev/null | tr -dc '0-9'
}

# ============================================================
# Helper: raw listening-socket table inside a container (TRL8/SCAS)
# Used for insecure-port checks and port-inventory evidence. Additive.
# ============================================================
container_listeners_raw() {
    docker exec "$1" sh -c "ss -ltun 2>/dev/null || netstat -ltun 2>/dev/null" 2>/dev/null || true
}

# ============================================================
# Helper: create a docker-log time cursor for current UTC time
# ============================================================
log_cursor_now() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# ============================================================
# Helper: grep docker logs since a given cursor
# ============================================================
docker_logs_grep_since() {
    local container_name="$1"
    local since_cursor="$2"
    local regex="$3"
    local lines="${4:-30}"

    local args=()
    if [ -n "$since_cursor" ]; then
        args+=(--since "$since_cursor")
    fi

    docker logs "${args[@]}" "$container_name" 2>&1 | grep -E "$regex" | tail -n "$lines" 2>/dev/null || true
}

# ============================================================
# Helper: grep recent docker logs without a time cursor
# ============================================================
docker_logs_recent_matches() {
    local container_name="$1"
    local regex="$2"
    local lines="${3:-30}"
    local tail_lines=$((lines * 12))

    docker logs --tail "$tail_lines" "$container_name" 2>&1 | grep -E "$regex" | tail -n "$lines" 2>/dev/null || true
}

# ============================================================
# Helper: capture current file-line cursor inside a container
# ============================================================
capture_container_file_cursor() {
    local container_name="$1"
    local file_path="$2"

    docker exec "$container_name" sh -c "if [ -f '$file_path' ]; then wc -l < '$file_path'; else echo 0; fi" 2>/dev/null | tr -dc '0-9'
}

# ============================================================
# Helper: grep only the lines appended after a stored file cursor
# ============================================================
container_file_grep_since_cursor() {
    local container_name="$1"
    local file_path="$2"
    local start_line="${3:-0}"
    local regex="$4"
    local lines="${5:-30}"

    local first_line=1
    if [ "$start_line" -gt 0 ] 2>/dev/null; then
        first_line=$((start_line + 1))
    fi

    docker exec "$container_name" sh -c "if [ -f '$file_path' ]; then tail -n +$first_line '$file_path' 2>/dev/null; fi" 2>/dev/null | grep -E "$regex" | tail -n "$lines" 2>/dev/null || true
}

# ============================================================
# Helper: grep recent matches from a container file
# ============================================================
container_file_recent_matches() {
    local container_name="$1"
    local file_path="$2"
    local regex="$3"
    local lines="${4:-30}"
    local tail_lines=$((lines * 12))

    docker exec "$container_name" sh -c "if [ -f '$file_path' ]; then tail -n '$tail_lines' '$file_path' 2>/dev/null; fi" 2>/dev/null | grep -E "$regex" | tail -n "$lines" 2>/dev/null || true
}

# ============================================================
# Helper: append a multiline diagnostic block to the report/log
# ============================================================
append_report_block() {
    local title="$1"
    local content="$2"

    if [ -z "$content" ]; then
        content="(no data)"
    fi

    # Evidence blocks (resource snapshots, Diameter peer dumps, AAR traces, log
    # excerpts) ALWAYS go to the per-feature report file. Echoing them to the
    # console too floods the terminal; gate that behind VERBOSE_DIAG so the
    # console shows only PASS/FAIL/SKIP lines + feature headers by default.
    echo "       ${title}:" >> "$_FEATURE_REPORT"
    [ "${VERBOSE_DIAG:-0}" = "1" ] && log "       ${title}:"
    while IFS= read -r line; do
        echo "         ${line}" >> "$_FEATURE_REPORT"
        [ "${VERBOSE_DIAG:-0}" = "1" ] && log "         ${line}"
    done <<< "$content"
}

# ============================================================
# Helper: capture one-shot docker CPU/memory/network stats for key containers
# ============================================================
capture_container_resource_snapshot() {
    local title="$1"
    shift

    local containers=("$@")
    local using_default_containers=0
    if [ "${#containers[@]}" -eq 0 ]; then
        # shellcheck disable=SC2206
        containers=($PROFILE_CONTAINERS)
        using_default_containers=1
    fi

    if [ "$using_default_containers" -eq 1 ] && [ "${INCLUDE_TEST_CONTAINER_STATS:-1}" = "1" ] && [ -r /etc/hostname ]; then
        local self_container
        self_container=$(cat /etc/hostname 2>/dev/null || true)
        if [ -n "$self_container" ] && docker inspect "$self_container" >/dev/null 2>&1; then
            containers+=("$self_container")
        fi
    fi

    local snapshot="NAME | STATUS | CPU | MEM | NET | BLOCK | PIDS"

    local container
    for container in "${containers[@]}"; do
        if ! docker inspect "$container" >/dev/null 2>&1; then
            snapshot="${snapshot}
${container} | missing | - | - | - | - | -"
            continue
        fi

        local state
        state=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null)
        state=${state:-unknown}

        if [ "$state" != "running" ]; then
            snapshot="${snapshot}
${container} | ${state} | - | - | - | - | -"
            continue
        fi

        local stats
        stats=$(docker stats --no-stream \
            --format '{{.CPUPerc}}|{{.MemUsage}}|{{.NetIO}}|{{.BlockIO}}|{{.PIDs}}' \
            "$container" 2>/dev/null | head -1)

        if [ -z "$stats" ]; then
            snapshot="${snapshot}
${container} | running | stats-unavailable | stats-unavailable | stats-unavailable | stats-unavailable | -"
            continue
        fi

        local cpu mem netio blockio pids
        cpu=$(echo "$stats" | cut -d'|' -f1)
        mem=$(echo "$stats" | cut -d'|' -f2)
        netio=$(echo "$stats" | cut -d'|' -f3)
        blockio=$(echo "$stats" | cut -d'|' -f4)
        pids=$(echo "$stats" | cut -d'|' -f5)

        snapshot="${snapshot}
${container} | ${state} | ${cpu} | ${mem} | ${netio} | ${blockio} | ${pids}"
    done

    append_report_block "$title" "$snapshot"
}

# ============================================================
# Helper: locate the RTPEngine container if one is running
# ============================================================
get_rtpengine_container() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -i "rtpengine" | head -1
}

# ============================================================
# Helper: capture media-path evidence from P-CSCF and RTPEngine
# Useful for call/conference/merge tests where SIP signaling alone is
# insufficient to explain the observed behavior.
# ============================================================
capture_media_path_evidence() {
    local title="$1"
    local regex="${2:-RTPENGINE|rtpengine_|offer|answer|delete|NATMANAGE|MODIFY_BW_RATE|sendonly|recvonly|inactive|m=audio|m=video}"
    local lines="${3:-40}"
    local since_cursor="${4:-}"

    local pcscf_media
    pcscf_media=$(docker_logs_grep_since "pcscf" "$since_cursor" "${regex}|RTPENGINE|rtpengine_|NATMANAGE|MODIFY_BW_RATE|offer|answer|delete" "$lines")
    append_report_block "${title} pcscf_media" "$pcscf_media"

    local pcscf_rtpengine
    pcscf_rtpengine=$(docker_exec "pcscf" "kamcmd rtpengine.show all 2>/dev/null | head -40" 2>/dev/null || true)
    append_report_block "${title} pcscf_rtpengine" "$pcscf_rtpengine"

    local rtpe_container
    rtpe_container=$(get_rtpengine_container)
    if [ -z "$rtpe_container" ]; then
        append_report_block "${title} rtpengine" "container not found"
        return
    fi

    local rtpe_proc
    rtpe_proc=$(docker exec "$rtpe_container" sh -c 'pgrep -af rtpengine 2>/dev/null || ps aux 2>/dev/null | grep [r]tpengine' 2>/dev/null || true)
    append_report_block "${title} rtpengine_process" "$rtpe_proc"

    local rtpe_net
    rtpe_net=$(docker exec "$rtpe_container" sh -c 'ss -lunp 2>/dev/null | head -40 || netstat -lunp 2>/dev/null | head -40 || cat /proc/net/udp 2>/dev/null | head -40' 2>/dev/null || true)
    append_report_block "${title} rtpengine_net" "$rtpe_net"

    local rtpe_logs
    rtpe_logs=$(docker_logs_grep_since "$rtpe_container" "$since_cursor" "${regex}|RTPENGINE|rtpengine|offer|answer|delete|session|stream|port" "$lines")
    append_report_block "${title} rtpengine_logs" "$rtpe_logs"
}

# ============================================================
# Helper: dump recent matching container logs into the report/log
# ============================================================
dump_container_log_matches() {
    local container_name="$1"
    local title="$2"
    local regex="$3"
    local lines="${4:-30}"
    local since_cursor="${5:-}"

    local snippet
    snippet=$(docker_logs_grep_since "$container_name" "$since_cursor" "$regex" "$lines")
    if [ -z "$snippet" ]; then
        if [ -n "$since_cursor" ]; then
            snippet=$(docker logs --since "$since_cursor" "$container_name" 2>&1 | tail -n "$lines" 2>/dev/null || echo "(no logs available)")
        else
            snippet=$(docker logs "$container_name" 2>&1 | tail -n "$lines" 2>/dev/null || echo "(no logs available)")
        fi
    fi

    append_report_block "$title" "$snippet"
}

# ============================================================
# Log helper
# ============================================================
log() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg"
}
