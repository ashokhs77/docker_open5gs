#!/bin/bash
#
# build_all_5g.sh — Build the Docker images for the 5G SA + VoNR DEPLOYMENT
#                   (5GC + IMS + their supporting infra). DEPLOYMENT ONLY.
#
# This builds ONLY what the 5G SA + VoNR deployment needs:
#   1/3  docker_open5gs   (base/)               — open5gs core binary (AMF SMF UPF NRF SCP AUSF UDM UDR PCF BSF NSSF)
#   2/3  docker_kamailio  (ims_base/)            — Kamailio IMS (P-CSCF I-CSCF S-CSCF SMSC)
#   3/3  compose images   (sa-vonr-deploy.yaml)  — webui dns rtpengine freeswitch mysql pyhss mmsc metrics
#
# It deliberately does NOT build any TEST-SUITE tooling. The 5G integration test
# runner image (docker_test_5g) and UERANSIM (the 5G gNB+UE simulator) are NOT
# built here because the deployment does not need them. They are built by the
# developer test-suite build:
#       sudo bash test/build_test_5g.sh
# Run that only when you want to exercise the test suite. Keeping test tooling out
# of this script keeps deployment builds lean and free of simulator dependencies.
#
# Key differences vs build_all.sh (4G):
#   * Compose file is sa-vonr-deploy.yaml instead of 4g-volte-deploy.yaml
#   * 5G does NOT build: osmohlr, osmomsc (4G/circuit-switched only; saves ~15-25 min)
#   * mmsc IS included: MMS rides over the 5G PDU session (SMPP -> SMSC in 5G SA)
#   * Adds: webui (Open5GS subscriber management UI, needed for 5G MongoDB provisioning)
#   * Enables BuildKit (DOCKER_BUILDKIT=1) for faster layer caching on re-builds
#   * Sequential compose builds (memory-bounded on small hosts)
#
# Usage (run from anywhere; script locates the repo root itself):
#   sudo ./build_all_5g.sh              Clean DEPLOYMENT build (5GC + IMS + infra)  [default]
#   sudo ./build_all_5g.sh --cache      Reuse layer cache (fast incremental rebuild)
#   sudo ./build_all_5g.sh --prune      docker system prune -af first, then clean build
#   sudo ./build_all_5g.sh --help

set -euo pipefail

# [OPT-1] Enable BuildKit for all docker build invocations
export DOCKER_BUILDKIT=1

COMPOSE_FILE="sa-vonr-deploy.yaml"

# Services in sa-vonr-deploy.yaml that have a build: context (DEPLOYMENT infra).
# IMPORTANT: mongo and all open5gs/kamailio NFs use pre-built images, not listed here.
# webui is included — 5G-SA only, needed for MongoDB subscriber provisioning.
# osmohlr/osmomsc are intentionally EXCLUDED (4G-only circuit-switched components).
COMPOSE_BUILD_SERVICES="${COMPOSE_BUILD_SERVICES:-webui dns rtpengine freeswitch mysql pyhss mmsc metrics}"

show_help() {
    cat <<'EOF'
build_all_5g.sh — build the Docker images for the 5G SA + VoNR DEPLOYMENT (5GC + IMS + infra).

This builds DEPLOYMENT images ONLY. It does NOT build the test suite — neither the
docker_test_5g runner nor UERANSIM (the 5G gNB+UE simulator). The deployment does not
need them. Build the test suite separately (developer-only):
       sudo bash test/build_test_5g.sh

Usage (run from anywhere; the script finds the repo root itself):
  sudo ./build_all_5g.sh              Clean deployment build (5GC + IMS + infra)  [default]
  sudo ./build_all_5g.sh --cache      Reuse layer cache (fast incremental rebuild)
  sudo ./build_all_5g.sh --prune      Run 'docker system prune -af' first, then clean build
  sudo ./build_all_5g.sh --help

Deployment build steps:
  1/3  docker_open5gs   (base/)               — open5gs core binary (5GC NFs)
  2/3  docker_kamailio  (ims_base/)            — Kamailio IMS CSCFs + SMSC
  3/3  compose images   (sa-vonr-deploy.yaml)  — webui dns rtpengine freeswitch mysql pyhss mmsc metrics

Notes:
  * --prune removes ALL unused images and build cache. Named volumes (MongoDB, MySQL data) are NOT removed.
  * Script re-execs itself under sudo (one password prompt) so all docker commands run as root.
  * Test suite (docker_test_5g + UERANSIM gNB/UE sim) is built by test/build_test_5g.sh — NOT here.
  * To build only specific compose services: COMPOSE_BUILD_SERVICES="dns pyhss" sudo ./build_all_5g.sh
EOF
}

# Handle --help before sudo re-exec
for a in "$@"; do
    case "$a" in -h|--help) show_help; exit 0 ;; esac
done

# Re-exec under sudo so all docker commands run as root (one password prompt)
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

# Locate repo root = directory containing this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Parse options
BUILD_FLAGS="--no-cache --force-rm"
COMPOSE_FLAGS="--no-cache"
DO_PRUNE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --cache)     BUILD_FLAGS=""; COMPOSE_FLAGS="" ;;
        --no-cache)  BUILD_FLAGS="--no-cache --force-rm"; COMPOSE_FLAGS="--no-cache" ;;
        --prune)     DO_PRUNE=1 ;;
        *) echo "Unknown option: $1 (try --help)"; exit 2 ;;
    esac
    shift
done

# Verify we are in the repo root (DEPLOYMENT inputs only — no test/ dependency)
for p in "base/Dockerfile" "ims_base/Dockerfile" "$COMPOSE_FILE"; do
    [ -e "$p" ] || {
        echo "ERROR: '$p' not found under $SCRIPT_DIR."
        echo "Place build_all_5g.sh in the docker_open5gs repo root."
        exit 1
    }
done

# Trap to report which step failed
CURRENT_STEP="startup"
trap 'rc=$?; [ $rc -ne 0 ] && printf "\n\033[1;31m#### BUILD FAILED at: %s (exit %d) ####\033[0m\n" "$CURRENT_STEP" "$rc"' EXIT

banner() { printf "\n\033[1;36m==== %s ====\033[0m\n" "$*"; }
secs_since() { echo "$(( $(date +%s) - $1 ))"; }
START_TS=$(date +%s)

# ─── Optional prune ──────────────────────────────────────────────────────────

if [ "$DO_PRUNE" -eq 1 ]; then
    CURRENT_STEP="docker system prune -af"
    banner "Pruning unused Docker images + build cache (named volumes preserved)"
    docker system prune -af
fi

# ─── Step 1/3: docker_open5gs (base) ─────────────────────────────────────────
# Used by: AMF SMF UPF NRF SCP AUSF UDM UDR PCF BSF NSSF (all 5G NFs share this image)
# This is the longest build step (~10–20 min depending on host).
CURRENT_STEP="1/3 docker_open5gs (base/)"
banner "[1/3] docker_open5gs — 5GC core binary ${BUILD_FLAGS:+(no-cache)}"
t0=$(date +%s)
docker build $BUILD_FLAGS -t docker_open5gs ./base
printf "   docker_open5gs built in %ss\n" "$(secs_since "$t0")"

# ─── Step 2/3: docker_kamailio (ims_base) ────────────────────────────────────
# Used by: P-CSCF I-CSCF S-CSCF SMSC (IMS for VoNR)
CURRENT_STEP="2/3 docker_kamailio (ims_base/)"
banner "[2/3] docker_kamailio — IMS CSCFs + SMSC ${BUILD_FLAGS:+(no-cache)}"
t0=$(date +%s)
docker build $BUILD_FLAGS -t docker_kamailio ./ims_base
printf "   docker_kamailio built in %ss\n" "$(secs_since "$t0")"

# ─── Step 3/3: compose images (sequential) ───────────────────────────────────
# Services built one at a time to keep peak RAM bounded on small hosts.
# rtpengine and freeswitch compile from C source and each need ~1-2 GB RAM.
# osmohlr/osmomsc are intentionally NOT here (4G-only; saves ~15-25 min).
CURRENT_STEP="3/3 docker compose build (sequential)"
banner "[3/3] compose images — built ONE AT A TIME ${COMPOSE_FLAGS:+(no-cache)}"
t0=$(date +%s)
for svc in $COMPOSE_BUILD_SERVICES; do
    CURRENT_STEP="3/3 docker compose build: $svc"
    banner "    building '$svc' ${COMPOSE_FLAGS:+(no-cache)}"
    s0=$(date +%s)
    docker compose -f "$COMPOSE_FILE" build $COMPOSE_FLAGS "$svc"
    printf "       %s built in %ss\n" "$svc" "$(secs_since "$s0")"
done
printf "   all compose images built in %ss\n" "$(secs_since "$t0")"

CURRENT_STEP="deployment done"
banner "ALL 5G DEPLOYMENT IMAGES BUILT OK in $(secs_since "$START_TS")s"


# ─── Done ─────────────────────────────────────────────────────────────────────

CURRENT_STEP="done"

echo ""
echo "Built deployment images:"
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' \
    | grep -E 'REPOSITORY|docker_open5gs|docker_kamailio|docker_dns|docker_rtpengine|docker_freeswitch|docker_mysql|docker_pyhss|docker_open5gs_webui|docker_metrics' \
    || true

echo ""
