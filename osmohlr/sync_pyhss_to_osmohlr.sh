#!/bin/bash
# =============================================================================
# PyHSS → OsmoHLR Subscriber Sync Script
# Fetches all subscribers from PyHSS API (paginated) and syncs to OsmoHLR
# - INSERT OR IGNORE: only inserts new subscribers (preserves existing IDs)
# - UPDATE: updates MSISDN if it changed for an existing IMSI
# Usage: ./sync_pyhss_to_osmohlr.sh
# =============================================================================

PYHSS_API="http://172.22.1.18:8080"
OSMOHLR_CONTAINER="osmohlr"
DB_PATH="/mnt/osmohlr/hlr.db"
PAGE_SIZE=200

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ── Checks ────────────────────────────────────────────────────────────────────
if ! docker ps --format '{{.Names}}' | grep -q "^${OSMOHLR_CONTAINER}$"; then
    log_error "Container '${OSMOHLR_CONTAINER}' is not running!"
    exit 1
fi

if ! docker exec "$OSMOHLR_CONTAINER" test -f "$DB_PATH"; then
    log_error "OsmoHLR database not found at ${DB_PATH}"
    exit 1
fi

if ! curl -s --max-time 5 "${PYHSS_API}/subscriber/list" > /dev/null 2>&1; then
    log_error "PyHSS API not reachable at ${PYHSS_API}"
    exit 1
fi

# ── Sync function ─────────────────────────────────────────────────────────────
sync_page() {
    local PAGE_DATA="$1"
    local PAGE_NUM="$2"

    local COUNT=$(echo "$PAGE_DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null)

    if [ "$COUNT" -eq 0 ]; then
        return 1  # No more data
    fi

    local SQL=$(echo "$PAGE_DATA" | python3 -c "
import sys, json
data = json.load(sys.stdin)
stmts = []
for sub in data:
    imsi   = str(sub.get('imsi', '')).strip()
    msisdn = str(sub.get('msisdn', '')).strip()
    if imsi and msisdn and msisdn != 'None':
        stmts.append(f\"INSERT OR IGNORE INTO subscriber (imsi, msisdn) VALUES ('{imsi}', '{msisdn}');\")
        stmts.append(f\"UPDATE subscriber SET msisdn='{msisdn}' WHERE imsi='{imsi}';\")
print(' '.join(stmts))
")

    if [ -z "$SQL" ]; then
        log_warn "Page $PAGE_NUM: no valid subscribers found"
        return 0
    fi

    docker exec "$OSMOHLR_CONTAINER" sqlite3 "$DB_PATH" "$SQL"
    if [ $? -eq 0 ]; then
        log_info "Page $PAGE_NUM: synced $COUNT subscribers"
    else
        log_error "Page $PAGE_NUM: SQL execution failed!"
        return 2
    fi

    return 0
}

# ── Paginated fetch and sync ──────────────────────────────────────────────────
log_info "Starting paginated sync from PyHSS (page size: ${PAGE_SIZE})..."

PAGE=1
TOTAL_SYNCED=0

while true; do
    log_info "Fetching page ${PAGE}..."

    PAGE_DATA=$(curl -s --max-time 10 \
        "${PYHSS_API}/subscriber/list?page=${PAGE}&page_size=${PAGE_SIZE}" 2>/dev/null)

    # Check if response is valid JSON array
    IS_VALID=$(echo "$PAGE_DATA" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(len(d) if isinstance(d, list) else -1)
except:
    print(-1)
" 2>/dev/null)

    if [ "$IS_VALID" -eq -1 ]; then
        log_error "Invalid response from PyHSS on page ${PAGE}"
        break
    fi

    if [ "$IS_VALID" -eq 0 ]; then
        log_info "No more subscribers found. Sync complete."
        break
    fi

    sync_page "$PAGE_DATA" "$PAGE"
    EXIT=$?

    if [ $EXIT -eq 1 ]; then
        log_info "All pages fetched."
        break
    elif [ $EXIT -eq 2 ]; then
        log_error "Stopping due to SQL error on page ${PAGE}"
        exit 1
    fi

    TOTAL_SYNCED=$((TOTAL_SYNCED + IS_VALID))

    # If page returned less than PAGE_SIZE, it's the last page
    if [ "$IS_VALID" -lt "$PAGE_SIZE" ]; then
        log_info "Last page reached (got $IS_VALID < $PAGE_SIZE)."
        break
    fi

    PAGE=$((PAGE + 1))
done

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
log_info "Verifying..."
TOTAL_DB=$(docker exec "$OSMOHLR_CONTAINER" sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM subscriber;")
log_info "Total subscribers in OsmoHLR DB: ${TOTAL_DB}"

echo ""
log_info "Sample - first and last 5 subscribers:"
docker exec "$OSMOHLR_CONTAINER" sqlite3 "$DB_PATH" \
    "SELECT id, imsi, msisdn FROM subscriber ORDER BY id LIMIT 5;"
echo "..."
docker exec "$OSMOHLR_CONTAINER" sqlite3 "$DB_PATH" \
    "SELECT id, imsi, msisdn FROM subscriber ORDER BY id DESC LIMIT 5;"

echo ""
log_info "Done! Restart OsmoHLR to apply changes:"
echo "  docker restart ${OSMOHLR_CONTAINER} osmomsc"
