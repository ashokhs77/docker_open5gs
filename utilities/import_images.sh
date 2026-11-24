#!/bin/bash
set -euo pipefail

PROJECT_DIR="docker_open5gs"

# find bundle
BUNDLE_TAR=$(ls offline_bundle_*.tar.gz 2>/dev/null | sort | tail -n 1 || true)
if [ -z "$BUNDLE_TAR" ]; then
  echo "❌ No offline_bundle_*.tar.gz found here."
  exit 1
fi

echo "📦 Using bundle: $BUNDLE_TAR"

TMPDIR="./tmp_import_$(date +%s)"
mkdir -p "$TMPDIR"

echo "🔓 Extracting bundle..."
tar -xzf "$BUNDLE_TAR" -C "$TMPDIR"

EXTRACT_DIR=$(find "$TMPDIR" -maxdepth 2 -type d -name "tmp_offline_bundle_*" -print -quit)
if [ -z "$EXTRACT_DIR" ]; then
  EXTRACT_DIR=$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d -print -quit)
fi

echo "📂 Extracted directory: $EXTRACT_DIR"

CODE_ARCHIVE="$EXTRACT_DIR/docker_open5gs.tar.gz"
IMAGES_ARCHIVE="$EXTRACT_DIR/docker_images.tar"

HAS_CODE="no"
HAS_IMAGES="no"

[ -f "$CODE_ARCHIVE" ] && HAS_CODE="yes"
[ -f "$IMAGES_ARCHIVE" ] && HAS_IMAGES="yes"

echo "Bundle contains: code=$HAS_CODE images=$HAS_IMAGES"

#############################
# IMPORT CODE
#############################
if [ "$HAS_CODE" = "yes" ]; then
    echo "📥 Importing code files into existing $PROJECT_DIR..."

    mkdir -p "$TMPDIR/code_extract"
    tar -xzf "$CODE_ARCHIVE" -C "$TMPDIR/code_extract"

    TOPDIR=$(find "$TMPDIR/code_extract" -mindepth 1 -maxdepth 1 -type d -print -quit)

    echo "🔁 Updating project files (files not in the bundle are left untouched)..."

    mkdir -p "$PROJECT_DIR"

    if command -v rsync >/dev/null 2>&1; then
        rsync -a "$TOPDIR"/ "$PROJECT_DIR"/
    else
        (cd "$TOPDIR" && tar -cf - .) | tar -xpf - -C "$PROJECT_DIR"
    fi

    echo "✅ Code updated."
fi    # <--- THIS "fi" WAS MISSING IN YOUR VERSION!

#############################
# IMPORT IMAGES
#############################
if [ "$HAS_IMAGES" = "yes" ]; then
    echo "🐳 Loading Docker images..."
    docker load -i "$IMAGES_ARCHIVE"
    echo "✅ Docker images loaded."
fi

#############################
# CLEANUP
#############################
echo "🧹 Cleaning up..."
rm -rf "$TMPDIR"
#rm -f "$BUNDLE_TAR"

cd $PROJECT_DIR

docker compose -f 4g-volte-deploy.yaml down

docker image prune -f


echo "✅ Import completed successfully!"
echo "Next steps:"
echo "  cd $PROJECT_DIR"
echo "  sudo docker compose -f 4g-volte-deploy.yaml up -d"

