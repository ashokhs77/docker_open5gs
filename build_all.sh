#!/bin/bash
#
# build_all.sh - Build all docker_open5gs images from scratch, in order:
#
#   1/3  docker_open5gs    (base/)       EPC/5GC core (open5gs)
#   2/3  docker_kamailio   (ims_base/)   IMS CSCFs + SMSC (kamailio)
#   3/3  compose images    (4g-volte-deploy.yaml): dns, rtpengine, freeswitch,
#        mysql, pyhss, osmohlr, osmomsc, mmsc, metrics
#
# DEPLOYMENT ONLY: builds the EPC + IMS + their infra and NOTHING test-related.
# The 4G integration test runner (docker_test) is built separately by the
# developer-only test-suite build:  sudo bash test/build_test.sh
#
# Replaces the manual sequence:
#   cd base       && sudo docker build --no-cache --force-rm -t docker_open5gs .
#   cd ../ims_base && sudo docker build --no-cache --force-rm -t docker_kamailio .
#   cd ..         && sudo docker compose -f 4g-volte-deploy.yaml build
#
# It stops at the first image that fails and tells you which one, so you never
# get a half-built set silently.

set -euo pipefail

COMPOSE_FILE="4g-volte-deploy.yaml"

show_help() {
    cat <<'EOF'
build_all.sh - build all docker_open5gs images in order (open5gs, kamailio, compose).

Usage (run from anywhere; the script finds the repo root itself):
  sudo ./build_all.sh              Clean build: --no-cache --force-rm  [default]
  sudo ./build_all.sh --cache      Reuse layer cache (fast incremental rebuild)
  sudo ./build_all.sh --prune      Run 'docker system prune -af' first, then clean build
  sudo ./build_all.sh --prune --cache
       ./build_all.sh --help

Builds (DEPLOYMENT only), in order:
  1/3  docker_open5gs   (base/)
  2/3  docker_kamailio  (ims_base/)
  3/3  compose images   (dns, rtpengine, freeswitch, mysql, pyhss, osmohlr,
                         osmomsc, mmsc, metrics)

Notes:
  * DEPLOYMENT images only. The test runner image (docker_test) is built
    separately (developer-only) by: sudo bash test/build_test.sh
  * --prune removes ALL unused images and build cache. Named volumes are NOT
    removed, so mysql/grafana data survive (matches 'docker system prune -a').
  * The script re-execs itself under sudo (one password prompt) so every build
    runs as root without re-prompting on long builds.
  * On any failure it prints "#### BUILD FAILED at: <step> ####" and exits non-zero.
EOF
}

# --- Handle --help BEFORE the sudo re-exec, so help needs no password ---
for a in "$@"; do
    case "$a" in -h|--help) show_help; exit 0 ;; esac
done

# --- Re-exec once under sudo so all docker commands run as root ---
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

# --- Locate repo root = directory containing this script ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- Parse options ---
BUILD_FLAGS="--no-cache --force-rm"   # for 'docker build' (steps 1-2)
COMPOSE_FLAGS="--no-cache"            # for 'docker compose build' (step 3)
DO_PRUNE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --cache)    BUILD_FLAGS=""; COMPOSE_FLAGS="" ;;
        --no-cache) BUILD_FLAGS="--no-cache --force-rm"; COMPOSE_FLAGS="--no-cache" ;;
        --prune)    DO_PRUNE=1 ;;
        *) echo "Unknown option: $1 (try --help)"; exit 2 ;;
    esac
    shift
done

# --- Confirm we are in the repo root ---
for p in "base/Dockerfile" "ims_base/Dockerfile" "$COMPOSE_FILE"; do
    [ -e "$p" ] || { echo "ERROR: '$p' not found under $SCRIPT_DIR."; \
                     echo "Place build_all.sh in the docker_open5gs repo root."; exit 1; }
done

# --- Report which step failed, if any ---
CURRENT_STEP="startup"
trap 'rc=$?; [ $rc -ne 0 ] && printf "\n\033[1;31m#### BUILD FAILED at: %s (exit %d) ####\033[0m\n" "$CURRENT_STEP" "$rc"' EXIT

banner() { printf "\n\033[1;36m==== %s ====\033[0m\n" "$*"; }
secs_since() { echo "$(( $(date +%s) - $1 ))"; }
START_TS=$(date +%s)

if [ "$DO_PRUNE" -eq 1 ]; then
    CURRENT_STEP="docker system prune -af"
    banner "Pruning unused Docker images + build cache (named volumes preserved)"
    docker system prune -af
fi

CURRENT_STEP="1/3 docker_open5gs (base/)"
banner "[1/3] docker_open5gs  - EPC/5GC core ${BUILD_FLAGS:+(no-cache)}"
t0=$(date +%s)
docker build $BUILD_FLAGS -t docker_open5gs ./base
printf "   docker_open5gs built in %ss\n" "$(secs_since "$t0")"

CURRENT_STEP="2/3 docker_kamailio (ims_base/)"
banner "[2/3] docker_kamailio - IMS CSCFs + SMSC ${BUILD_FLAGS:+(no-cache)}"
t0=$(date +%s)
docker build $BUILD_FLAGS -t docker_kamailio ./ims_base
printf "   docker_kamailio built in %ss\n" "$(secs_since "$t0")"

CURRENT_STEP="3/3 docker compose build (sequential)"
banner "[3/3] compose images - built ONE AT A TIME to fit small VMs ${COMPOSE_FLAGS:+(no-cache)}"
t0=$(date +%s)
# IMPORTANT: build compose images sequentially, not with a bare
# `docker compose build` (which builds them in PARALLEL by default).
# Several of these compile from source (rtpengine, freeswitch, ...); running
# them concurrently on a small host (e.g. 5 CPU / 6 GB RAM) exhausts RAM+swap
# and HANGS the machine. One-at-a-time keeps peak memory bounded.
# COMPOSE_BUILD_SERVICES = the services in 4g-volte-deploy.yaml that have a
# `build:` context (the open5gs/kamailio services use prebuilt images and are
# NOT built here). Override via env if the compose file changes.
COMPOSE_BUILD_SERVICES="${COMPOSE_BUILD_SERVICES:-dns rtpengine freeswitch mysql pyhss osmohlr osmomsc mmsc metrics}"
for svc in $COMPOSE_BUILD_SERVICES; do
    CURRENT_STEP="3/3 docker compose build: $svc"
    banner "    building '$svc' ${COMPOSE_FLAGS:+(no-cache)}"
    s0=$(date +%s)
    docker compose -f "$COMPOSE_FILE" build $COMPOSE_FLAGS "$svc"
    printf "       %s built in %ss\n" "$svc" "$(secs_since "$s0")"
done
printf "   all compose images built in %ss\n" "$(secs_since "$t0")"

CURRENT_STEP="deployment done"
banner "ALL 4G DEPLOYMENT IMAGES BUILT OK in $(secs_since "$START_TS")s"


CURRENT_STEP="done"
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' \
    | grep -E 'REPOSITORY|docker_open5gs|docker_kamailio|docker_dns|docker_rtpengine|docker_freeswitch|docker_mysql|docker_pyhss|docker_osmohlr|docker_osmomsc|^mmsc|docker_metrics' || true
echo
