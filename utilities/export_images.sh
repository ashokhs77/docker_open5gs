#!/bin/bash
set -euo pipefail

PROJECT_DIR="docker_open5gs"
TIMESTAMP="$(date +%Y%m%d_%H%M)"
OUT_DIR="./tmp_offline_bundle_$TIMESTAMP"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "❌ ERROR: $PROJECT_DIR not found in current directory."
    exit 1
fi

mkdir -p "$OUT_DIR"

echo "================ EXPORT TYPE ================"
echo "1) CODE ONLY"
echo "2) IMAGES ONLY"
echo "3) CODE + IMAGES"
echo "============================================"
read -p "Select (1/2/3): " MODE

###############################################
# Create CODE archive (.env / dispatcher.list optional)
###############################################
create_code_archive() {
    read -p "Include .env in the bundle? (y/N): " INC_ENV
    read -p "Include dispatcher.list files in the bundle? (y/N): " INC_DISP

    EXCLUDES=()
    [[ "$INC_ENV"  =~ ^[Yy]$ ]] || EXCLUDES+=(--exclude="${PROJECT_DIR}/.env")
    [[ "$INC_DISP" =~ ^[Yy]$ ]] || EXCLUDES+=(--exclude="*/dispatcher.list")

    echo " Creating code archive (.env: ${INC_ENV:-n}, dispatcher.list: ${INC_DISP:-n})..."

    tar ${EXCLUDES[@]+"${EXCLUDES[@]}"} \
      -czf "$OUT_DIR/${PROJECT_DIR}.tar.gz" "$PROJECT_DIR"

    echo " Code archive: $OUT_DIR/${PROJECT_DIR}.tar.gz"
}

###############################################
# Get dynamic Docker images from system
###############################################
get_image_list() {
    docker images --format "{{.Repository}}:{{.Tag}}" | grep -v "<none>" || true
}

###############################################
# Export ALL Docker images
###############################################
create_images_archive_all() {
    IMAGES=( $(get_image_list) )
    if [ ${#IMAGES[@]} -eq 0 ]; then
        echo "⚠️ No docker images found."
        return 1
    fi

    echo " Exporting ALL images..."
    docker save "${IMAGES[@]}" -o "$OUT_DIR/docker_images.tar"
    printf "%s\n" "${IMAGES[@]}" > "$OUT_DIR/images_list.txt"
    echo " All images exported."
}

###############################################
# Export selected images
###############################################
create_images_archive_selected() {
    IMAGES=( $(get_image_list) )
    if [ ${#IMAGES[@]} -eq 0 ]; then
        echo "No docker images found."
        return 1
    fi

    printf "%s\n" "${IMAGES[@]}" > "$OUT_DIR/images_list.txt"

    echo " Available images:"
    nl -ba "$OUT_DIR/images_list.txt"
    read -p "Enter image numbers (e.g. 1 3 5): " selection

    SELECTED_IMAGES=()
    for num in $selection; do
        img=$(sed -n "${num}p" "$OUT_DIR/images_list.txt")
        if [ -n "$img" ]; then
            SELECTED_IMAGES+=("$img")
        fi
    done

    if [ ${#SELECTED_IMAGES[@]} -eq 0 ]; then
        echo "⚠️ No valid images selected."
        return 1
    fi

    echo " Exporting selected images..."
    docker save "${SELECTED_IMAGES[@]}" -o "$OUT_DIR/docker_images.tar"
    printf "%s\n" "${SELECTED_IMAGES[@]}" > "$OUT_DIR/images_list.txt"
    echo " Selected images exported."
}

###############################################
# Mode handling
###############################################
case "$MODE" in
  1)
    create_code_archive
    LABEL="code_only"
    ;;
  2)
    echo "Export images:"
    echo "  a) ALL"
    echo "  b) SELECT"
    read -p "Choose (a/b): " CH
    if [ "$CH" = "a" ]; then create_images_archive_all; else create_images_archive_selected; fi
    LABEL="images_only"
    ;;
  3)
    create_code_archive
    echo "Export images:"
    echo "  a) ALL"
    echo "  b) SELECT"
    read -p "Choose (a/b): " CH
    if [ "$CH" = "a" ]; then create_images_archive_all; else create_images_archive_selected; fi
    LABEL="code_images"
    ;;
  *)
    echo "❌ Invalid selection."
    exit 1
    ;;
esac

###############################################
# Create final bundle
###############################################
FINAL_BUNDLE="offline_bundle_${TIMESTAMP}_${LABEL}.tar.gz"
tar -czf "$FINAL_BUNDLE" -C "$(dirname "$OUT_DIR")" "$(basename "$OUT_DIR")"
rm -rf "$OUT_DIR"

echo " Final bundle created: $FINAL_BUNDLE"
#echo "➡ Move this file to the offline machine."

