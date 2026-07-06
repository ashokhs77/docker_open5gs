#!/bin/bash
# UERANSIM multi-UE load helpers for the 5G capacity / stress tests.
#
# Drives REAL registration + PDU-session concurrency via `nr-ue -n N` against
# DEDICATED load gNB(s) — never the functional nr-gnb/nr-ue. A single UERANSIM
# gNB process SIGSEGVs above ~256-512 simultaneous UEs, so we cap each load gNB
# at UE_LOAD_GNB_CAP (256, validated safe) and SHARD across multiple load gNBs
# for higher targets (512 = 2 cells). The 5G CORE handles >=512 registered UEs +
# PDU sessions at ~0% CPU on this box — the ceiling is the simulator, not the core.
#
# Isolation / safety: touches ONLY transient nr-gnb-load-* / nr-ue-load-* containers
# and a dedicated load subscriber range (IMSI 001010000000101+). The functional
# nr-gnb / nr-ue / ...0001 subscriber are never modified, so functional 5G evidence
# (registration / pdu / vonr) is preserved for the rest of the suite. Pure tooling.

UE_LOAD_IMG="${UE_LOAD_IMG:-gradiant/ueransim:3.2.6}"
UE_LOAD_BASE_N="${UE_LOAD_BASE_N:-101}"                 # load MSIN base (functional UE is 1)
UE_LOAD_GNB_CAP="${UE_LOAD_GNB_CAP:-256}"               # max UEs per load gNB (UERANSIM limit)
UE_LOAD_MAX_GNB="${UE_LOAD_MAX_GNB:-2}"                 # load gNB configs available (.211,.212)
UE_LOAD_UE_YAML="${UE_LOAD_UE_YAML:-/opt/test/ueransim/ue.yaml}"
UE_LOAD_PROV_JS="${UE_LOAD_PROV_JS:-/opt/test/ueransim/provision_5g_range.js}"
UE_LOAD_GNB_CONTAINER="${UE_LOAD_GNB_CONTAINER:-nr-gnb}"

_ue_load_net() {
    local c net
    # Resolve the deploy network from a container known to be on it. Prefer the
    # functional gNB, but fall back to core NFs (amf/smf/nrf) so the dedicated
    # load gNBs attach to the right network even when the functional nr-gnb is
    # NOT running (otherwise they'd land on the wrong/guessed network and fail
    # NG Setup, yielding 0 registrations).
    for c in "$UE_LOAD_GNB_CONTAINER" amf smf nrf; do
        net=$(docker inspect "$c" \
            --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null)
        [ -n "$net" ] && { echo "$net"; return 0; }
    done
    echo docker_open5gs_default
}

# IMSI for a given MSIN number: "00101" + 10-digit MSIN.  $1=number
_ue_load_imsi() { printf '00101%010d' "$1"; }

# Host-side path of a file in the ueransim dir, for `docker run -v` (the daemon
# resolves HOST paths, not the test container's). In-container: derive from this
# container's own bind-mount Source. On the host: the configured dir is the host
# dir. Uses the ueransim mount, falling back to the always-present reports mount.
_ue_load_host_path() {
    local self src
    self=$(hostname)
    src=$(docker inspect "$self" --format \
        '{{range .Mounts}}{{if eq .Destination "/opt/test/ueransim"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
    [ -z "$src" ] && src=$(docker inspect "$self" --format \
        '{{range .Mounts}}{{if eq .Destination "/opt/test/reports"}}{{.Source}}{{end}}{{end}}' 2>/dev/null \
        | sed 's#/reports$#/ueransim#')
    [ -z "$src" ] && src=$(dirname "$UE_LOAD_UE_YAML")
    echo "${src%/}/$1"
}

# Provision a range of load subscribers (idempotent). $1=count [$2=base]
provision_5g_load_subs() {
    local count="${1:-512}" base="${2:-$UE_LOAD_BASE_N}"
    [ -f "$UE_LOAD_PROV_JS" ] || { echo "prov-js-missing"; return 1; }
    printf 'var LOAD_BASE=%s;var LOAD_COUNT=%s;\n' "$base" "$count" \
        | cat - "$UE_LOAD_PROV_JS" \
        | docker exec -i mongo mongo open5gs --quiet 2>/dev/null | tail -1
}

# Ensure the FUNCTIONAL gNB has a live NG association; restart it (+ functional UE)
# only if stale. Best-effort. (Not needed by the load ramps — they use their own
# gNBs — but kept for callers that want the functional path healthy.)
ensure_5g_gnb_ng() {
    if docker logs --tail 120 "$UE_LOAD_GNB_CONTAINER" 2>&1 | grep -q "NG Setup procedure is successful" \
       && ! docker logs --tail 25 "$UE_LOAD_GNB_CONTAINER" 2>&1 | grep -qi "AMF selection.*failed"; then
        return 0
    fi
    docker restart "$UE_LOAD_GNB_CONTAINER" >/dev/null 2>&1; sleep 7
    docker restart nr-ue >/dev/null 2>&1; sleep 8
    docker logs --tail 30 "$UE_LOAD_GNB_CONTAINER" 2>&1 | grep -q "NG Setup procedure is successful"
}

# Bring up dedicated load gNB k (static IP 172.22.1.(211+k)); wait for NG Setup. $1=k
_ue_load_gnb_up() {
    local k="$1" net ip cfg name="nr-gnb-load-$1" attempt w
    net=$(_ue_load_net); ip="172.22.1.$(( 211 + k ))"; cfg=$(_ue_load_host_path "gnb_load_${k}.yaml")
    for attempt in 1 2; do                       # retry once if NG Setup doesn't land
        docker rm -f "$name" >/dev/null 2>&1; sleep 2   # let the static IP fully release
        docker run -d --name "$name" --network "$net" --ip "$ip" \
            --entrypoint nr-gnb -v "${cfg}:/gnb.yaml:ro" "$UE_LOAD_IMG" -c /gnb.yaml >/dev/null 2>&1
        w=0
        while [ "$w" -lt 18 ]; do
            docker logs "$name" 2>&1 | grep -q "NG Setup procedure is successful" && return 0
            sleep 2; w=$(( w + 2 ))
        done
    done
    return 1
}

# Launch UE shard k (N UEs based at IMSI $3) against load gNB k. $1=k $2=count $3=base_imsi
_ue_load_ue_up() {
    local k="$1" count="$2" base="$3" net cfg name="nr-ue-load-$1"
    net=$(_ue_load_net); cfg=$(_ue_load_host_path "ue_load_${k}.yaml")
    docker rm -f "$name" >/dev/null 2>&1
    docker run -d --name "$name" --network "$net" --cap-add NET_ADMIN --device /dev/net/tun \
        --entrypoint nr-ue -v "${cfg}:/ue.yaml:ro" "$UE_LOAD_IMG" \
        -c /ue.yaml -i "$base" -n "$count" >/dev/null 2>&1
}

# Sum a log marker across all running UE shards. $1=marker
_ue_load_count() {
    local marker="$1" total=0 c n
    for c in $(docker ps --format '{{.Names}}' | grep '^nr-ue-load-' 2>/dev/null); do
        n=$(docker logs "$c" 2>&1 | grep -c "$marker"); total=$(( total + n ))
    done
    echo "$total"
}

# Remove all transient load shards (UEs + gNBs). Functional nr-gnb/nr-ue untouched.
ue_load_teardown() {
    local c
    for c in $(docker ps -aq --filter 'name=nr-ue-load-' 2>/dev/null); do docker rm -f "$c" >/dev/null 2>&1; done
    for c in $(docker ps -aq --filter 'name=nr-gnb-load-' 2>/dev/null); do docker rm -f "$c" >/dev/null 2>&1; done
}

# Register N UEs across ceil(N/CAP) dedicated load gNBs. Polls until registered>=N
# or the count plateaus. Echoes: "<registered> <pdu> <elapsed_seconds>".
# $1=N  [$2=max_wait_seconds]
ue_load_register() {
    local N="$1" maxw="${2:-90}"
    ue_load_teardown; sleep 1
    local ngnb=$(( ( N + UE_LOAD_GNB_CAP - 1 ) / UE_LOAD_GNB_CAP ))
    [ "$ngnb" -lt 1 ] && ngnb=1
    [ "$ngnb" -gt "$UE_LOAD_MAX_GNB" ] && ngnb="$UE_LOAD_MAX_GNB"
    local k t0 t1 launched=0 reg=0 last=-1 stable=0 w=0
    t0=$(date +%s)
    for k in $(seq 0 $(( ngnb - 1 ))); do _ue_load_gnb_up "$k" >/dev/null 2>&1 || true; done
    for k in $(seq 0 $(( ngnb - 1 ))); do
        local n=$(( N - launched )); [ "$n" -gt "$UE_LOAD_GNB_CAP" ] && n="$UE_LOAD_GNB_CAP"
        [ "$n" -le 0 ] && break
        _ue_load_ue_up "$k" "$n" "$(_ue_load_imsi $(( UE_LOAD_BASE_N + launched )))"
        launched=$(( launched + n ))
    done
    while [ "$w" -lt "$maxw" ]; do
        sleep 4; w=$(( w + 4 ))
        reg=$(_ue_load_count "Registration is successful")
        [ "$reg" -ge "$N" ] && break
        if [ "$reg" -eq "$last" ]; then stable=$(( stable + 1 )); else stable=0; fi
        last="$reg"; [ "$stable" -ge 3 ] && break
    done
    t1=$(date +%s)
    local pdu; pdu=$(_ue_load_count "PDU Session establishment is successful")
    echo "$reg $pdu $(( t1 - t0 ))"
}

# ============================================================
# Conformance signalling trigger (NAS / NGAP evidence helper)
# ============================================================
# Drive ONE isolated transient UE through register -> PDU -> de-register so that
# fresh NAS/NGAP procedure evidence (5G-AKA, SUCI, NAS Security Mode, Registration
# Accept/5G-GUTI, InitialUEMessage, RAN/AMF_UE_NGAP_ID, PDU establishment,
# De-registration / UE Context Release) is emitted into the AMF/SMF/AUSF/UDM logs
# *since a cursor*, so the conformance procedure-evidence TCs can PASS on real
# evidence instead of SKIPping "not observed in window".
#
# Safety / isolation: uses ONLY the transient load gNB/UE machinery
# (nr-gnb-load-0 / nr-ue-load-0, load subscriber IMSI ...0101) — NEVER the
# functional nr-gnb / nr-ue / ...0001 subscriber. Best-effort, idempotent, and
# cached (runs at most once per suite run). On ANY failure it falls back silently;
# the conformance TCs then keep their existing recent-window grep + honest SKIP
# behaviour, so this can never break the suite.
#
# Exports: CONFORMANCE_TRIGGER_DONE / CONFORMANCE_TRIGGER_OK / CONFORMANCE_TRIGGER_CURSOR
# Returns 0 if registration evidence was generated, non-zero otherwise.
conformance_trigger_5g_signalling() {
    if [ "${CONFORMANCE_TRIGGER_DONE:-0}" = "1" ]; then
        [ "${CONFORMANCE_TRIGGER_OK:-0}" = "1" ]
        return
    fi
    CONFORMANCE_TRIGGER_DONE=1
    CONFORMANCE_TRIGGER_OK=0
    CONFORMANCE_TRIGGER_CURSOR=$(log_cursor_now)

    # Fast viability gate: need docker, a running AMF, and a usable UERANSIM image
    # (functional nr-gnb running is a strong signal the image is present).
    command -v docker >/dev/null 2>&1 || return 1
    container_is_running "amf" || return 1
    container_is_running "nr-gnb" || docker image inspect "$UE_LOAD_IMG" >/dev/null 2>&1 || return 1

    # Provision + register ONE transient load UE on a dedicated load gNB.
    provision_5g_load_subs 1 >/dev/null 2>&1 || true
    local res reg
    res=$(ue_load_register 1 60 2>/dev/null)
    reg=$(echo "$res" | awk '{print $1}'); reg=${reg:-0}
    [ "$reg" -ge 1 ] 2>/dev/null && CONFORMANCE_TRIGGER_OK=1

    # Clean switch-off de-registration (NAS Deregistration + NGAP UE Context Release),
    # then remove the transient shards. Functional UE untouched.
    local c imsi
    imsi=$(_ue_load_imsi "$UE_LOAD_BASE_N")
    for c in $(docker ps --format '{{.Names}}' | grep '^nr-ue-load-' 2>/dev/null); do
        docker exec "$c" nr-cli "imsi-${imsi}" -e "deregister switch-off" >/dev/null 2>&1 || true
    done
    sleep 3
    ue_load_teardown

    [ "$CONFORMANCE_TRIGGER_OK" = "1" ]
}

# Echo evidence from the trigger window (since CONFORMANCE_TRIGGER_CURSOR).
# Non-zero/empty if the trigger did not run or produced no cursor.
# $1=container  $2=regex  [$3=lines]
conformance_trig_grep() {
    [ "${CONFORMANCE_TRIGGER_OK:-0}" = "1" ] || return 1
    [ -n "${CONFORMANCE_TRIGGER_CURSOR:-}" ] || return 1
    docker_logs_grep_since "$1" "$CONFORMANCE_TRIGGER_CURSOR" "$2" "${3:-12}"
}

# Evidence accessor used by the conformance features: PREFER fresh trigger-window
# evidence; if absent (trigger didn't run / nothing found), fall back to the exact
# recent-window grep used previously. Same call shape as docker_logs_recent_matches,
# so when the trigger is unavailable the behaviour is byte-identical to before.
# $1=container  $2=regex  [$3=lines]
conformance_evidence() {
    local ev
    ev=$(conformance_trig_grep "$1" "$2" "${3:-6}")
    if [ -n "$ev" ]; then
        printf '%s\n' "$ev"
        return 0
    fi
    docker_logs_recent_matches "$1" "$2" "${3:-6}"
}
