#!/bin/bash
# Common test helpers for 5G SA + VoNR integration test suite
# Sourced by all 5G feature scripts

set +e

# ============================================================
# Environment (from docker env or defaults)
# ============================================================
# Test topology: 'internal' (runner + core on same VM, default) or 'external'
# (runner on a separate generator VM targeting a remote 5G core — see
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
# 5G Core NFs
AMF_IP="${AMF_IP:-172.22.1.10}"
AMF_SBI_PORT="${AMF_SBI_PORT:-7777}"
NRF_IP="${NRF_IP:-172.22.1.12}"
NRF_PORT="${NRF_PORT:-7777}"
SCP_IP="${SCP_IP:-172.22.1.35}"
SCP_PORT="${SCP_PORT:-7777}"
AUSF_IP="${AUSF_IP:-172.22.1.11}"
AUSF_PORT="${AUSF_PORT:-7777}"
UDM_IP="${UDM_IP:-172.22.1.13}"
UDM_PORT="${UDM_PORT:-7777}"
UDR_IP="${UDR_IP:-172.22.1.14}"
UDR_PORT="${UDR_PORT:-7777}"
PCF_IP="${PCF_IP:-172.22.1.27}"
PCF_PORT="${PCF_PORT:-7777}"
BSF_IP="${BSF_IP:-172.22.1.29}"
BSF_PORT="${BSF_PORT:-7777}"
NSSF_IP="${NSSF_IP:-172.22.1.28}"
NSSF_PORT="${NSSF_PORT:-7777}"
SMF_IP="${SMF_IP:-172.22.1.7}"
SMF_SBI_PORT="${SMF_SBI_PORT:-7777}"
UPF_IP="${UPF_IP:-172.22.1.8}"

# IMS components (same as 4G — shared stack for VoNR)
PCSCF_IP="${PCSCF_IP:-172.22.1.21}"
PCSCF_PORT="${PCSCF_PORT:-5060}"
ICSCF_IP="${ICSCF_IP:-172.22.1.19}"
SCSCF_IP="${SCSCF_IP:-172.22.1.20}"
FREESWITCH_IP="${FREESWITCH_IP:-172.22.1.150}"
PYHSS_IP="${PYHSS_IP:-172.22.1.18}"
RTPENGINE_IP="${RTPENGINE_IP:-172.22.1.16}"
SMSC_IP="${SMSC_IP:-172.22.1.33}"

# Infrastructure
MONGO_IP="${MONGO_IP:-172.22.1.2}"
MYSQL_IP="${MYSQL_IP:-172.22.1.17}"
DNS_IP="${DNS_IP:-172.22.1.15}"
# LOCAL_IP: bind/Contact/Via + UE-sim transport. Internal mode: the compose passes
# 172.22.1.200 (no-op). External mode: derived from LOAD_GENERATOR_IP, then the
# route to AMF_IP, then a safe default.
if [ -z "${LOCAL_IP:-}" ] && [ -n "$LOAD_GENERATOR_IP" ]; then
    LOCAL_IP="$LOAD_GENERATOR_IP"
    LOCAL_IP_SOURCE="LOAD_GENERATOR_IP"
elif [ -z "${LOCAL_IP:-}" ] && [ "$TEST_TOPOLOGY" = "external" ] && command -v ip >/dev/null 2>&1; then
    LOCAL_IP=$(ip route get "$AMF_IP" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    [ -n "$LOCAL_IP" ] && LOCAL_IP_SOURCE="auto-route"
fi
if [ -z "${LOCAL_IP:-}" ]; then
    LOCAL_IP="172.22.1.200"
    LOCAL_IP_SOURCE="default"
fi
# Keep the shared IMS realm aligned with the DNS container, which derives its
# zone from the deployment's existing MCC/MNC values.
MCC="${MCC:-001}"
MNC="${MNC:-01}"
if [ -z "${IMS_DOMAIN:-}" ]; then
    if [ ${#MNC} -eq 3 ]; then
        _IMS_MNC="$MNC"
    else
        _IMS_MNC="0${MNC}"
    fi
    IMS_DOMAIN="ims.mnc${_IMS_MNC}.mcc${MCC}.3gppnetwork.org"
fi
export IMS_DOMAIN

# Docker host IP: where host-networked services (MMSC runs network_mode: host) and
# host-published ports are reachable from the test runner. Prefer an explicit value;
# otherwise auto-detect this container's default gateway (= the Docker host) so the
# suite is portable across hosts with no hardcoded lab IP.
if [ -z "${DOCKER_HOST_IP:-}" ]; then
    DOCKER_HOST_IP="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
fi
export DOCKER_HOST_IP

WEBUI_IP="${WEBUI_IP:-172.22.1.26}"
DOCKER_HOST_LABEL="${DOCKER_HOST:-local/default}"
INCLUDE_TEST_CONTAINER_STATS="${INCLUDE_TEST_CONTAINER_STATS:-1}"

# Misc
PYHSS_API_KEY="${PYHSS_API_KEY:-}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-MySQL_PaSsW0rD}"
REPORT_DIR="/opt/test/reports"
VERBOSE_DIAG="${VERBOSE_DIAG:-0}"
INCLUDE_TEST_CONTAINER_STATS="${INCLUDE_TEST_CONTAINER_STATS:-1}"

# 5G containers to profile
PROFILE_CONTAINERS="${PROFILE_CONTAINERS:-amf smf upf nrf scp ausf udm udr pcf bsf nssf mongo pcscf icscf scscf freeswitch pyhss mysql dns}"

# UERANSIM RAN container that owns the UE PDU-session tunnel (uesimtun0).
UE_SIM_RAN_CONTAINER="${UE_SIM_RAN_CONTAINER:-nr-ue}"

# ============================================================
# 5G user-plane iperf3 helper (UE -> gNB -> UPF)
# ============================================================
# Run an iperf3 client from the UERANSIM UE (nr-ue) through its PDU-session tunnel
# (uesimtun0) to the UPF data-plane gateway. The UE-pool subnet (10.45.0.0/16) is
# reachable ONLY through the tunnel — not from the test container's bridge — and the
# UE's main route to it goes via eth0, so we install a route via uesimtun0 first.
# (iperf3 3.9 has no --bind-dev; callers add -M for TCP to clamp MSS to the GTP-U MTU.)
# Echoes iperf3 output. Returns 70 if the UE tunnel is unavailable.
# Usage: ue_dataplane_iperf3 <upf_tun_ip> <iperf3 args...>
ue_dataplane_iperf3() {
    local upf_ip="$1"; shift
    local ue_ip
    ue_ip=$(docker exec "$UE_SIM_RAN_CONTAINER" sh -c \
        'ip -br addr show uesimtun0 2>/dev/null | awk "{print \$3}" | cut -d/ -f1' 2>/dev/null)
    [ -z "$ue_ip" ] && return 70
    docker exec "$UE_SIM_RAN_CONTAINER" sh -c "ip route replace ${upf_ip} dev uesimtun0 src ${ue_ip} 2>/dev/null"
    docker exec "$UE_SIM_RAN_CONTAINER" timeout 25 iperf3 -c "$upf_ip" "$@" 2>&1
}

# Start a detached iperf3 server in the UPF bound to its data-plane TUN IP and wait
# until it is listening on :5201. Uses `docker exec -d` (Docker-level detach): an
# `iperf3 -D` launched via `docker exec sh -c` does NOT survive the exec returning.
# Returns 0 once listening, 1 on timeout.
upf_iperf3_server() {
    local bind_ip="$1" i
    docker exec upf sh -c "pkill -f 'iperf3 -s' 2>/dev/null" >/dev/null 2>&1
    docker exec -d upf iperf3 -s -B "$bind_ip" >/dev/null 2>&1
    for i in 1 2 3 4 5 6; do
        docker exec upf sh -c "ss -lnt 2>/dev/null | grep -q ':5201 '" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# Light, non-disruptive user-plane reachability check via the UE PDU-session tunnel
# (ICMP through uesimtun0). Bulk throughput is intentionally NOT attempted: the
# UERANSIM userspace GTP-U datapath stalls under bulk load and can drop the PDU
# session, so line-rate throughput is REAL_HW-gated. Echoes the ping packet-loss
# string (e.g. "0% packet loss"); returns 70 if the UE tunnel is unavailable.
ue_dataplane_ping() {
    local target="$1" count="${2:-5}" ue_ip
    ue_ip=$(docker exec "$UE_SIM_RAN_CONTAINER" sh -c 'ip -br addr show uesimtun0 2>/dev/null | awk "{print \$3}" | cut -d/ -f1' 2>/dev/null)
    [ -z "$ue_ip" ] && return 70
    docker exec "$UE_SIM_RAN_CONTAINER" sh -c "ping -I uesimtun0 -c $count -W 2 $target 2>&1 | grep -oE '[0-9]+% packet loss' | tail -1" 2>/dev/null
}

fiveg_upf_tun_ip() {
    container_is_running "upf" || return 1
    docker exec upf sh -c 'for i in ogstun ogstun2; do ip -4 addr show "$i" 2>/dev/null | awk "/inet /{print \$2}" | cut -d/ -f1; done | head -1' 2>/dev/null
}

fiveg_ue_tunnel_addr() {
    container_is_running "$UE_SIM_RAN_CONTAINER" || return 1
    docker exec "$UE_SIM_RAN_CONTAINER" sh -c 'ip -br addr show uesimtun0 2>/dev/null | awk "{print \$3}" | head -1' 2>/dev/null
}

# Strong live evidence that an N4-created PDU session exists: the UPF has a
# data-plane TUN address and UERANSIM owns a UE PDU-session tunnel address.
# This complements log greps, because Open5GS may not emit PFCP association
# and session strings at the default log level on every run.
fiveg_active_pdu_session_evidence() {
    local upf_tun_ip ue_addr
    upf_tun_ip=$(fiveg_upf_tun_ip | head -1 | tr -d '\r')
    ue_addr=$(fiveg_ue_tunnel_addr | head -1 | tr -d '\r')

    if [ -n "$upf_tun_ip" ] && [ -n "$ue_addr" ]; then
        echo "UE ${UE_SIM_RAN_CONTAINER} uesimtun0=${ue_addr}; UPF TUN=${upf_tun_ip}"
        return 0
    fi
    return 1
}

# Weaker, non-session evidence that the N4 peer path is configured/reachable.
# Callers should pass on active PDU evidence, skip on endpoint-only evidence,
# and fail only when the peer path is both expected and absent.
fiveg_n4_endpoint_evidence() {
    local smf_cfg upf_cfg
    container_is_running "smf" && container_is_running "upf" || return 1

    if container_listens_on_port "smf" 8805 && container_listens_on_port "upf" 8805; then
        echo "SMF and UPF PFCP endpoints listen on UDP/8805"
        return 0
    fi

    smf_cfg=$(read_nf_config smf)
    upf_cfg=$(read_nf_config upf)
    if echo "$smf_cfg" | grep -qiE 'pfcp|upf' && echo "$upf_cfg" | grep -qiE 'pfcp|smf'; then
        echo "SMF/UPF N4 peer configuration is present; listener probe inconclusive"
        return 0
    fi

    return 1
}

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
    log "5G test suite initialized"
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

    _GLOBAL_PASS=$((_GLOBAL_PASS + _FEATURE_PASS))
    _GLOBAL_FAIL=$((_GLOBAL_FAIL + _FEATURE_FAIL))
    _GLOBAL_SKIP=$((_GLOBAL_SKIP + _FEATURE_SKIP))
    _GLOBAL_TOTAL=$((_GLOBAL_TOTAL + _FEATURE_TOTAL))

    local summary_line
    summary_line=$(printf "%-30s %5d %5d %5d %5d" "$_FEATURE_NAME" "$_FEATURE_TOTAL" "$_FEATURE_PASS" "$_FEATURE_FAIL" "$_FEATURE_SKIP")
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
        echo "  5G SA + VoNR Integration Test Suite - Summary Report"
        echo "  Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  Duration: ${minutes}m ${seconds}s"
        echo "============================================================"
        echo ""
        printf "%-30s %5s %5s %5s %5s\n" "Feature" "Total" "Pass" "Fail" "Skip"
        echo "-------------------------------------------------------------------"
        echo "$_FEATURE_SUMMARIES"
        echo "-------------------------------------------------------------------"
        printf "%-30s %5d %5d %5d %5d\n" "TOTAL" "$_GLOBAL_TOTAL" "$_GLOBAL_PASS" "$_GLOBAL_FAIL" "$_GLOBAL_SKIP"
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
                echo "         Common reasons: UERANSIM not deployed, no subscribers provisioned."
            fi
        fi
        # Warn if pass count is suspiciously low
        if [ "$_GLOBAL_PASS" -lt 10 ] && [ "$_GLOBAL_TOTAL" -gt 20 ]; then
            echo ""
            echo "WARNING: Only ${_GLOBAL_PASS} tests passed out of ${_GLOBAL_TOTAL} total."
            echo "         Most tests may be skipping due to missing 5G NF dependencies."
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
# Helper: run a mongo eval, auto-detecting shell version
#
# MongoDB 6.0  (production/deployment) uses  mongosh
# MongoDB 4.4  (test-suite VM)         uses  mongo   (legacy shell)
#
# Usage:
#   mongo_eval  ""          "db.runCommand({ping:1}).ok"
#   mongo_eval  "open5gs"   "db.subscribers.find().count()"
#   mongo_eval  "open5gs"   "db.getCollectionNames().join(',')"
#
# The shell is auto-detected once per container exec: mongosh if present,
# otherwise mongo.  Both accept --quiet and the same --eval syntax.
# ============================================================
_MONGO_SHELL=""   # cached after first detection

_detect_mongo_shell() {
    if [ -n "$_MONGO_SHELL" ]; then return 0; fi
    if docker exec mongo which mongosh >/dev/null 2>&1; then
        _MONGO_SHELL="mongosh"
    else
        _MONGO_SHELL="mongo"
    fi
}

mongo_eval() {
    local db="${1}"      # empty string → no db arg (uses default 'test')
    local eval_cmd="${2}"

    _detect_mongo_shell

    if [ -n "$db" ]; then
        docker exec mongo "$_MONGO_SHELL" --quiet "$db" --eval "$eval_cmd" 2>/dev/null
    else
        docker exec mongo "$_MONGO_SHELL" --quiet --eval "$eval_cmd" 2>/dev/null
    fi
}

# ============================================================
# Helper: HTTP GET a 5G SBI endpoint and check HTTP status
# Returns 0 if HTTP 2xx received, 1 otherwise
# Open5GS NFs use HTTP/2 (libmicrohttpd); --http2-prior-knowledge skips
# HTTP/1.1 upgrade negotiation.  Without it curl gets "Empty reply" → 000.
# ============================================================
sbi_get() {
    local url="$1"
    local http_code
    http_code=$(curl -s --http2-prior-knowledge -o /dev/null -w "%{http_code}" \
        --max-time 5 \
        -H "Accept: application/json" \
        "$url" 2>/dev/null || echo "000")
    case "$http_code" in
        2*) return 0 ;;
        *)  echo "$http_code"; return 1 ;;
    esac
}

# ============================================================
# Helper: HTTP GET and capture response body + code
# Usage: result=$(sbi_get_body URL); code=$(echo "$result" | tail -1)
# ============================================================
sbi_get_body() {
    local url="$1"
    curl -s --http2-prior-knowledge -w "\n%{http_code}" \
        --max-time 5 \
        -H "Accept: application/json" \
        "$url" 2>/dev/null || echo -e "\n000"
}

# ============================================================
# Helper: check port open (TCP)
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
# Helper: check if a container has restarted (restart count > 0)
# ============================================================
container_restart_count() {
    local name="$1"
    docker inspect --format '{{.RestartCount}}' "$name" 2>/dev/null || echo "0"
}

# ============================================================
# Helper: check if a container is listening on a port internally
# Works for SCTP listeners (AMF NGAP 38412) as well as TCP/UDP.
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
# Helper: check whether AMF NGAP is actually ready
# (analogous to mme_s1ap_ready() in the 4G suite)
# ============================================================
amf_ngap_ready() {
    container_is_running "amf" || return 1
    container_listens_on_port "amf" 38412 || return 1
    return 0
}

# ============================================================
# Helper: check DNS A record
# ============================================================
check_dns_a() {
    local fqdn="$1"
    local expected_ip="$2"
    local result
    result=$(dig +short "$fqdn" @"$DNS_IP" A 2>/dev/null | head -1 | tr -d '[:space:]')
    [ "$result" = "$expected_ip" ]
}

# ============================================================
# Helper: check DNS SRV record
# ============================================================
check_dns_srv() {
    local fqdn="$1"
    local expected_port="$2"
    local result
    result=$(dig +short SRV "$fqdn" @"$DNS_IP" 2>/dev/null)
    echo "$result" | grep -q "$expected_port"
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
# Helper: docker exec shortcut
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
# Usage: cfg=$(read_nf_config amf)
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
# Helper: create docker-log time cursor
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
# Helper: append a multiline diagnostic block to the report
# ============================================================
append_report_block() {
    local title="$1"
    local content="$2"

    [ -z "$content" ] && content="(no data)"

    echo "       ${title}:" >> "$_FEATURE_REPORT"
    log "       ${title}:"
    while IFS= read -r line; do
        echo "         ${line}" >> "$_FEATURE_REPORT"
        log "         ${line}"
    done <<< "$content"
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
# Helper: locate RTPEngine container
# ============================================================
get_rtpengine_container() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -i "rtpengine" | head -1
}

# ============================================================
# Helper: capture one-shot docker CPU/memory/network stats
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
# Helper: capture media-path evidence from P-CSCF and RTPEngine
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
    rtpe_net=$(docker exec "$rtpe_container" sh -c 'ss -lunp 2>/dev/null | head -40 || netstat -lunp 2>/dev/null | head -40' 2>/dev/null || true)
    append_report_block "${title} rtpengine_net" "$rtpe_net"

    local rtpe_logs
    rtpe_logs=$(docker_logs_grep_since "$rtpe_container" "$since_cursor" "${regex}|RTPENGINE|rtpengine|offer|answer|delete|session|stream|port" "$lines")
    append_report_block "${title} rtpengine_logs" "$rtpe_logs"
}

# ============================================================
# Helper: dump recent matching container logs into the report
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
# Hardware and container resource probe
# ============================================================
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

init_hardware_probe() {
    {
        echo "5G SA + VoNR Hardware Inventory"
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

    if [ "${HW_PROBE_ENABLED:-0}" = "1" ]; then
        start_hardware_probe
    fi
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
        echo "5G SA + VoNR Hardware and Resource Usage Report"
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
                    if (mem_peak > max_mem_peak[name]) max_mem_peak[name]=mem_peak
                    if (mem_current > max_mem_current[name]) max_mem_current[name]=mem_current
                    if (io_r > max_io_r[name]) max_io_r[name]=io_r
                    if (io_w > max_io_w[name]) max_io_w[name]=io_w
                    if (pids > max_pids[name]) max_pids[name]=pids
                    if (!(name in first_cpu) && cpu > 0) first_cpu[name]=cpu
                    if (cpu > 0) last_cpu[name]=cpu
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
                }
            ' "$_HW_CHECKPOINT_FILE"
        fi
        echo ""
        echo "Optional sampled Docker stats"
        echo "============================="
        if [ ! -s "$_HW_SAMPLE_FILE" ] || [ "$(wc -l < "$_HW_SAMPLE_FILE" 2>/dev/null || echo 0)" -le 1 ]; then
            echo "Docker stats sampling is disabled by default. Enable HW_PROBE_ENABLED=1 for approximate instantaneous CPU% peaks."
        else
            awk -F',' '
                function to_mib(v, n, u){
                    v=v+0; u=v
                    sub(/^[0-9.]+[ \t]*/, "", u)
                    if (u ~ /^KiB$/) return v/1024
                    if (u ~ /^MiB$/) return v
                    if (u ~ /^GiB$/) return v*1024
                    if (u ~ /^kB$/)  return v/1024
                    if (u ~ /^MB$/)  return v*1000000/1048576
                    if (u ~ /^GB$/)  return v*1000000000/1048576
                    return v
                }
                NR==1 { next }
                {
                    name=$2
                    cpu=$3; gsub(/%/, "", cpu); cpu+=0
                    split($4, mp, "/"); mem_mib=to_mib(mp[1])
                    seen[name]=1
                    if (cpu > max_cpu[name]) max_cpu[name]=cpu
                    if (mem_mib > max_mem[name]) max_mem[name]=mem_mib
                }
                END {
                    printf "%-24s %12s %14s\n", "Container", "MaxCPU%", "MaxRAMMiB"
                    print "----------------------------------------------------"
                    for (name in seen) printf "%-24s %12.2f %14.1f\n", name, max_cpu[name], max_mem[name]
                }
            ' "$_HW_SAMPLE_FILE"
        fi
    } > "$hw_report"

    log "Hardware/resource report written to: ${hw_report}"
}

# ============================================================
# Explain what a test result means (5G context)
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
                echo "    Meaning: required containers are running and not crash-looping."
                ;;
            *"nrf"*"register"*|*"registered with nrf"*)
                echo "    Meaning: the NF has successfully announced itself to the 5G NRF via SBI."
                ;;
            *"sbi"*"reachable"*|*"port 7777"*)
                echo "    Meaning: SBI HTTP/2 interface is up and accepting connections."
                ;;
            *"mongodb"*"ping"*|*"open5gs"*"database"*)
                echo "    Meaning: MongoDB subscriber store is online and the open5gs database exists."
                ;;
            *"vonr"*|*"voip"*|*"invite"*"bye"*|*"invite"*"non-5xx"*)
                echo "    Meaning: IMS/VoNR call signaling path is working end-to-end."
                ;;
            *"pdu session"*|*"pfcp"*|*"n4"*)
                echo "    Meaning: 5G data-plane (SMF↔UPF N4 PFCP) is established."
                ;;
            *"dns"*)
                echo "    Meaning: DNS records required for IMS/VoNR routing are resolvable."
                ;;
            *"slicing"*|*"nssf"*|*"s-nssai"*)
                echo "    Meaning: 5G network slice selection infrastructure is correctly configured."
                ;;
            *"throughput"*|*"capacity"*|*"jitter"*|*"load"*)
                echo "    Meaning: the measured capacity/performance point met the suite threshold."
                ;;
            *"cdr"*|*"call detail"*)
                echo "    Meaning: call detail records are being written with valid structure."
                ;;
            *"security"*|*"401"*|*"481"*|*"483"*|*"dos"*)
                echo "    Meaning: the IMS/SBI security posture check passed."
                ;;
            *)
                echo "    Meaning: this validation point passed for the current deployment."
                ;;
        esac
        return
    fi

    if [ "$status" = "SKIP" ]; then
        case "$combined" in
            *"ueransim"*|*"nr-gnb"*|*"nr-ue"*)
                echo "    Why: UERANSIM gNB/UE simulator is not running in the compose stack."
                echo "    To enable: start UERANSIM and rerun --feature registration or --feature pdu_session."
                ;;
            *"subscriber"*"0"*|*"no subscriber"*)
                echo "    Why: no 5G subscribers are provisioned in MongoDB."
                echo "    To enable: add subscribers via WebUI at http://VM_IP:9999 then rerun."
                ;;
            *"mmsc"*|*"mms"*|*"kannel"*|*"mbuni"*)
                echo "    Why: the optional MMSC/MMS stack is not running."
                echo "    To enable: start the MMSC service and verify Kannel/Mbuni/MM7 paths."
                ;;
            *"scenario"*"not found"*)
                echo "    Why: the required SIPp scenario XML file is missing from /opt/test/scenarios/."
                echo "    To enable: add the scenario file to the test container image."
                ;;
            *)
                echo "    Why: ${detail:-the test declared its prerequisite unavailable.}"
                echo "    To enable: satisfy the skipped test prerequisite and rerun this feature."
                ;;
        esac
        return
    fi

    case "$combined" in
        *"nrf"*)
            echo "    Issue: NRF SBI connectivity or NF registration failed."
            echo "    To address: check NRF container logs, NF SBI endpoint configuration, and NRF registration retry."
            ;;
        *"mongodb"*)
            echo "    Issue: MongoDB connectivity or subscriber database check failed."
            echo "    To address: check MongoDB container state, AVX support (mongo 4.4 needed on VirtualBox), and open5gs database init."
            ;;
        *"pdu session"*|*"pfcp"*|*"n4"*)
            echo "    Issue: 5G data-plane (PFCP/N4) association or PDU session failed."
            echo "    To address: check SMF/UPF container logs, N4 interface config, and PFCP association log entries."
            ;;
        *"registration"*|*"ngap"*)
            echo "    Issue: UE registration or NGAP connectivity failed."
            echo "    To address: check AMF logs, UERANSIM gNB/UE config, PLMN/NSSAI match, and MongoDB subscriber credentials."
            ;;
        *"vonr"*|*"invite"*)
            echo "    Issue: VoNR/IMS call signaling failed."
            echo "    To address: check P-CSCF/S-CSCF/FreeSWITCH logs, DNS records, RTPEngine state, and PDU session IMS APN."
            ;;
        *"security"*|*"dos"*)
            echo "    Issue: security probe returned an unexpected response or the target crashed."
            echo "    To address: review the SIP stack (Kamailio P-CSCF) error logs and crash indicators."
            ;;
        *)
            echo "    Issue: ${detail:-the test assertion failed.}"
            echo "    To address: inspect the feature report and container logs, fix the prerequisite, and rerun."
            ;;
    esac
}

append_core_limitations() {
    cat <<'EOF'
5G SA + VoNR suite limitations
==============================
- Load capacity results are deployment-local (VM/container resources); not universal production limits.
- UERANSIM-based registration/PDU session tests require the nr-ue simulator in the compose stack.
- NRF SBI checks use HTTP/2 (--http2-prior-knowledge); SBI responses use HAL+JSON _links format.
- MongoDB subscriber checks require at least one subscriber provisioned via the WebUI.
- RTPEngine checks may rely on container/process evidence when the NG control port is not reachable from the test container.
- VoNR IMS tests use the shared P/I/S-CSCF + FreeSWITCH stack; failures may indicate 4G VoLTE issues as well.
- MMS, MMSC, and Kannel/Mbuni are optional paths; skipped unless the MMSC service is deployed.
- Network slicing defaults to SST=1 (eMBB); multi-slice tests require additional NSSF/SMF configuration.

Test suite limitations
======================
- PASS means the configured scenario passed in this test environment.
- SKIP means a prerequisite or optional component is unavailable; skipped tests are coverage gaps.
- Load tests use synthetic gNB/SIPp behavior and may not model all handset, radio, or IPSec conditions.
- The generated explanations are rule-based; detailed root cause still requires logs when a test fails.
- MongoDB version split: production uses mongo:6.0 (mongosh), test VM uses mongo:4.4 (mongo shell).
  The mongo_eval() helper auto-detects the available shell at runtime.
EOF
}

append_hardware_spec_summary() {
    echo "Hardware used for this run"
    echo "=========================="
    if [ ! -f "$_HW_HOST_FILE" ]; then
        echo "Hardware inventory was not captured."
        return 0
    fi

    local kernel cores model cpu_count mem_line root_df
    kernel=$(sed -n 's/^Kernel: //p' "$_HW_HOST_FILE" | head -1)
    cores=$(sed -n 's/^CPU cores available to test container: //p' "$_HW_HOST_FILE" | head -1)
    model=$(sed -n 's/^  Model name:[[:space:]]*//p' "$_HW_HOST_FILE" | head -1)
    cpu_count=$(sed -n 's/^  CPU(s):[[:space:]]*//p' "$_HW_HOST_FILE" | head -1)
    mem_line=$(awk '/^  Mem:/ {print; exit}' "$_HW_HOST_FILE")
    root_df=$(awk '/^  Filesystem/ {getline; print; exit}' "$_HW_HOST_FILE")

    [ -n "$kernel" ] && echo "Kernel: ${kernel}"
    [ -n "$model" ] && echo "CPU model: ${model}"
    [ -n "$cores" ] && echo "CPU cores visible to test container: ${cores}"
    [ -n "$cpu_count" ] && echo "Host CPU(s): ${cpu_count}"
    [ -n "$mem_line" ] && echo "RAM: ${mem_line#  }"
    [ -n "$root_df" ] && echo "Root filesystem: ${root_df#  }"
    echo "Detailed hardware/resource report: ${REPORT_DIR}/hardware_resource_report.txt"
}

generate_detailed_report() {
    local detailed_file="${REPORT_DIR}/detailed_test_report.txt"
    local generated_at
    generated_at=$(date '+%Y-%m-%d %H:%M:%S')

    {
        echo "5G SA + VoNR Integration Suite"
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
        printf "%-30s %5s %5s %5s %5s\n" "Feature" "Total" "Pass" "Fail" "Skip"
        echo "-------------------------------------------------------------------"
        echo "$_FEATURE_SUMMARIES"
        echo "-------------------------------------------------------------------"
        printf "%-30s %5d %5d %5d %5d\n" "TOTAL" "$_GLOBAL_TOTAL" "$_GLOBAL_PASS" "$_GLOBAL_FAIL" "$_GLOBAL_SKIP"
        echo ""
        echo "What is working fine"
        echo "===================="
        if [ "$_GLOBAL_PASS" -eq 0 ]; then
            echo "No passed tests were recorded in this run."
        else
            local report_file feature line
            for report_file in $_FEATURE_REPORT_FILES; do
                [ -f "$report_file" ] || continue
                case "$(basename "$report_file")" in
                    summary.txt|detailed_test_report.txt) continue ;;
                esac
                feature=$(sed -n 's/^Feature: //p' "$report_file" | head -1)
                [ -n "$feature" ] || feature="$(basename "$report_file" .txt)"
                while IFS= read -r line; do
                    case "$line" in
                        "[PASS] TC-"*)
                            local tc desc
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
            local report_file feature line
            for report_file in $_FEATURE_REPORT_FILES; do
                [ -f "$report_file" ] || continue
                case "$(basename "$report_file")" in
                    summary.txt|detailed_test_report.txt) continue ;;
                esac
                feature=$(sed -n 's/^Feature: //p' "$report_file" | head -1)
                [ -n "$feature" ] || feature="$(basename "$report_file" .txt)"
                while IFS= read -r line; do
                    case "$line" in
                        "[FAIL] TC-"*)
                            local tc desc err
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
            local report_file feature line
            for report_file in $_FEATURE_REPORT_FILES; do
                [ -f "$report_file" ] || continue
                case "$(basename "$report_file")" in
                    summary.txt|detailed_test_report.txt) continue ;;
                esac
                feature=$(sed -n 's/^Feature: //p' "$report_file" | head -1)
                [ -n "$feature" ] || feature="$(basename "$report_file" .txt)"
                while IFS= read -r line; do
                    case "$line" in
                        "[SKIP] TC-"*)
                            local tc desc reason
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
        append_core_limitations
        echo ""
        echo "Recommended next actions"
        echo "========================"
        if [ "$_GLOBAL_FAIL" -gt 0 ]; then
            echo "1. Fix failed tests first; they represent active runtime or threshold failures."
        else
            echo "1. No failed tests were recorded; focus on skipped coverage."
        fi
        if [ "$_GLOBAL_SKIP" -gt 0 ]; then
            echo "2. Review skipped tests: provision 5G subscribers (WebUI:9999) and deploy UERANSIM for registration/PDU session coverage."
            echo "3. Enable optional paths (MMSC, multi-slice) one at a time, then rerun the affected feature."
        else
            echo "2. Keep the generated report with the run artifacts for release evidence."
        fi
        echo "4. Treat load/capacity numbers as baselines; tune and rerun before production sizing."
    } > "$detailed_file"

    log "Detailed report written to: ${detailed_file}"
}

# ============================================================
# Log helper
# ============================================================
log() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg"
}
