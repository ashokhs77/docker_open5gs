#!/bin/bash
#
# build_test_5g.sh — Build the 5G TEST SUITE tooling (DEVELOPER-ONLY).
#
# The deployment build (../build_all_5g.sh) deliberately does NOT build any of
# this. Run this ONLY when you want to exercise the 5G test suite. It builds:
#   1) docker_test_5g                — the 5G integration test runner image (Dockerfile.5g)
#   2) UERANSIM (gradiant/ueransim)  — the 5G gNB+UE software simulator used by the
#                                      RAN/UE-dependent test cases (registration, ngap_n2_5g,
#                                      nas_conformance_5g, pdu_session, perf_kpi UE-plane KPIs)
#
# NOTE on "building" UERANSIM: UERANSIM here is a PRE-BUILT image we PULL
# (gradiant/ueransim:3.2.6) — it is NOT compiled from source (no cmake toolchain
# is required on the host). "Build" therefore means: ensure the image is present
# locally. The gNB/UE run as standalone nr-gnb / nr-ue containers launched by
# ueransim/bringup_ueransim.sh; they are NOT part of any deployment compose file,
# so they never start during a normal deployment.
#
# Usage (run from anywhere; the script finds the test dir itself):
#   sudo bash build_test_5g.sh                  Build test runner + prepare UERANSIM  [default]
#   sudo bash build_test_5g.sh --cache          Reuse layer cache for the test runner image
#   sudo bash build_test_5g.sh --only-ueransim  Only prepare UERANSIM (skip the test runner image)
#   sudo bash build_test_5g.sh --only-runner    Only build the test runner image (skip UERANSIM)
#   sudo bash build_test_5g.sh --help
#
# Override the UERANSIM image tag with:  UERANSIM_IMG=gradiant/ueransim:3.2.6 sudo bash build_test_5g.sh

set -euo pipefail
export DOCKER_BUILDKIT=1

UERANSIM_IMG="${UERANSIM_IMG:-gradiant/ueransim:3.2.6}"
TEST_IMAGE="docker_test_5g"
TEST_DOCKERFILE="Dockerfile.5g"

show_help() {
    cat <<'EOF'
build_test_5g.sh — build the 5G TEST SUITE tooling (developer-only).

Builds the 5G integration test runner image (docker_test_5g) and prepares
UERANSIM (the 5G gNB+UE simulator, a pre-built image that is pulled, not compiled).
The deployment (build_all_5g.sh) does NOT build any of this.

Usage (run from anywhere; the script finds the test dir itself):
  sudo bash build_test_5g.sh                  Build test runner + prepare UERANSIM  [default]
  sudo bash build_test_5g.sh --cache          Reuse layer cache for the test runner image
  sudo bash build_test_5g.sh --only-ueransim  Only prepare UERANSIM (skip the test runner image)
  sudo bash build_test_5g.sh --only-runner    Only build the test runner image (skip UERANSIM)
  sudo bash build_test_5g.sh --help

Notes:
  * UERANSIM is a PRE-BUILT image (gradiant/ueransim:3.2.6) — "build" = docker pull if missing.
    Override the tag with the UERANSIM_IMG env var.
  * The gNB/UE run as standalone nr-gnb / nr-ue containers via ueransim/bringup_ueransim.sh;
    they are NOT in any deployment compose file and never start during a normal deployment.
EOF
}

for a in "$@"; do
    case "$a" in -h|--help) show_help; exit 0 ;; esac
done

# Re-exec under sudo so docker runs as root (invoke via bash so no +x needed)
if [ "$(id -u)" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

# Locate the test dir = directory containing this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_FLAGS="--no-cache --force-rm"
DO_RUNNER=1
DO_UERANSIM=1
while [ $# -gt 0 ]; do
    case "$1" in
        --cache)         BUILD_FLAGS="" ;;
        --no-cache)      BUILD_FLAGS="--no-cache --force-rm" ;;
        --only-ueransim) DO_RUNNER=0 ;;
        --only-runner)   DO_UERANSIM=0 ;;
        *) echo "Unknown option: $1 (try --help)"; exit 2 ;;
    esac
    shift
done

banner() { printf "\n\033[1;36m==== %s ====\033[0m\n" "$*"; }
START_TS=$(date +%s)

# ─── 1/2: 5G test runner image (docker_test_5g) ──────────────────────────────
if [ "$DO_RUNNER" -eq 1 ]; then
    [ -f "$TEST_DOCKERFILE" ] || { echo "ERROR: $TEST_DOCKERFILE not found in $SCRIPT_DIR"; exit 1; }
    banner "[1/2] docker_test_5g — 5G integration test runner ${BUILD_FLAGS:+(no-cache)}"
    t0=$(date +%s)
    docker build $BUILD_FLAGS -f "$TEST_DOCKERFILE" -t "$TEST_IMAGE" .
    printf "   %s built in %ss\n" "$TEST_IMAGE" "$(( $(date +%s) - t0 ))"
else
    banner "[1/2] SKIPPED test runner image (--only-ueransim)"
fi

# ─── 2/2: UERANSIM 5G gNB+UE simulator (pre-built image; pull if missing) ─────
if [ "$DO_UERANSIM" -eq 1 ]; then
    banner "[2/2] UERANSIM 5G gNB+UE simulator — ensuring image present: $UERANSIM_IMG"
    if docker image inspect "$UERANSIM_IMG" >/dev/null 2>&1; then
        echo "   $UERANSIM_IMG already present (no pull needed)."
    else
        echo "   pulling $UERANSIM_IMG ..."
        docker pull "$UERANSIM_IMG"
        echo "   $UERANSIM_IMG pulled."
    fi
else
    banner "[2/2] SKIPPED UERANSIM (--only-runner)"
fi

banner "5G TEST SUITE BUILD OK in $(( $(date +%s) - START_TS ))s"
echo ""
echo "Run the test suite (against a running 5G core):"
echo "  # 1) start UERANSIM (5G gNB + UE) — provisions a subscriber and brings up nr-gnb/nr-ue:"
echo "  sudo bash $SCRIPT_DIR/ueransim/bringup_ueransim.sh"
echo "  # 2) run the 5G suite (TRL8 add-on shown; use --bundle full for the core suite):"
echo "  sudo docker compose -f $SCRIPT_DIR/docker-compose.test5g.yaml run --rm sipp-test-5g --bundle trl8"
echo ""
echo "  # 5GC core smoke tests need NO UERANSIM:"
echo "  sudo docker compose -f $SCRIPT_DIR/docker-compose.test5g.yaml run --rm sipp-test-5g --bundle 5gc"
