#!/bin/bash
#
# build_test.sh — Build the 4G TEST SUITE tooling (DEVELOPER-ONLY).
#
# The deployment build (../build_all.sh) deliberately does NOT build this. Run
# this ONLY when you want to exercise the 4G EPC + VoLTE test suite. It builds:
#   1) docker_test — the 4G integration test runner image (test/Dockerfile)
#
# The 4G UE simulator (test/ue_sim — a Python EPS/NAS/S1AP/SIP sim) is NOT a
# separate image: it is baked into docker_test (COPY ue_sim/) and also volume-
# mounted at runtime for live edits. So unlike 5G there is NO simulator image to
# pull — the 4G test build is just the test runner image. (5G's UERANSIM is the
# only pulled sim; see test/build_test_5g.sh.)
#
# Usage (run from anywhere; the script finds the test dir itself):
#   sudo bash build_test.sh           Build the 4G test runner image (docker_test)  [default]
#   sudo bash build_test.sh --cache   Reuse layer cache (fast incremental rebuild)
#   sudo bash build_test.sh --help

set -euo pipefail
export DOCKER_BUILDKIT=1

TEST_IMAGE="docker_test"
TEST_DOCKERFILE="Dockerfile"

show_help() {
    cat <<'EOF'
build_test.sh — build the 4G TEST SUITE tooling (developer-only).

Builds the 4G integration test runner image (docker_test). The deployment
(build_all.sh) does NOT build this. The 4G UE sim (test/ue_sim) is Python and is
baked into the image — there is no separate sim image to pull (unlike 5G's UERANSIM).

Usage (run from anywhere; the script finds the test dir itself):
  sudo bash build_test.sh           Build the 4G test runner image (docker_test)  [default]
  sudo bash build_test.sh --cache   Reuse layer cache (fast incremental rebuild)
  sudo bash build_test.sh --help
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
while [ $# -gt 0 ]; do
    case "$1" in
        --cache)    BUILD_FLAGS="" ;;
        --no-cache) BUILD_FLAGS="--no-cache --force-rm" ;;
        *) echo "Unknown option: $1 (try --help)"; exit 2 ;;
    esac
    shift
done

banner() { printf "\n\033[1;36m==== %s ====\033[0m\n" "$*"; }
START_TS=$(date +%s)

[ -f "$TEST_DOCKERFILE" ] || { echo "ERROR: $TEST_DOCKERFILE not found in $SCRIPT_DIR"; exit 1; }
banner "docker_test — 4G integration test runner ${BUILD_FLAGS:+(no-cache)}"
t0=$(date +%s)
docker build $BUILD_FLAGS -f "$TEST_DOCKERFILE" -t "$TEST_IMAGE" .
printf "   %s built in %ss\n" "$TEST_IMAGE" "$(( $(date +%s) - t0 ))"

banner "4G TEST SUITE BUILD OK in $(( $(date +%s) - START_TS ))s"
echo ""
echo "Run the test suite (against a running 4G EPC + IMS stack):"
echo "  sudo docker compose -f $SCRIPT_DIR/docker-compose.test.yaml run --rm sipp-test --bundle tec"
echo "  # or a single feature:"
echo "  sudo docker compose -f $SCRIPT_DIR/docker-compose.test.yaml run --rm sipp-test --feature volte"
