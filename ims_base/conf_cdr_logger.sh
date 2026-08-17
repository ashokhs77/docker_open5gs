#!/bin/bash
#
# Conference CDR logger — writes formatted conference CDR rows to
# /cdr-logs/conf_cdr.csv.
#
# Two record types share the file, distinguished by column 1 (RecordType):
#   LEG  : one row per participant leg (join -> leave)
#   CONF : one summary row per bridge, emitted when the last participant leaves
#
# Behaviour required by design:
#   * newest record is always kept on TOP of the file (prepend, not append)
#   * only the last 7 days of records are retained (older rows are dropped on
#     every write) so the CSV can never grow unbounded
#
# Positional arguments (all mandatory; empty string fields are passed as ''):
#   1  RECORD_TYPE   LEG | CONF
#   2  CONF_HOST     first dialer of the bridge
#   3  PARTICIPANTS  LEG: this participant; CONF: ';'-separated list (may be empty)
#   4  TOTAL_COUNT   LEG: active count at leave; CONF: peak participant count
#   5  MEDIA_TYPE    audio | video
#   6  START_EPOCH   Unix epoch seconds (converted to human-readable StartTime)
#   7  DURATION      seconds (integer)
#   8  BRIDGE_ID     conference bridge number (1NNR)
#   9  END_REASON    e.g. NORMAL (leg) / CONF_ENDED (summary)

REC="$1"
HOST="$2"
PARTS="$3"
COUNT="$4"
MEDIA="$5"
START_EPOCH="$6"
DURATION="$7"
BRIDGE="$8"
END_REASON="$9"

CSV="/cdr-logs/conf_cdr.csv"
HEADER="RecordType,ConfHost,Participants,TotalParticipantCount,MediaType,StartTime,Duration,ConfBridgeID,EndReason"
RETAIN_DAYS=7

# Human-readable start time; fall back to the raw value if conversion fails.
START_TIME_HR=$(date -d "@$START_EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
[ -z "$START_TIME_HR" ] && START_TIME_HR="$START_EPOCH"

NEW_LINE="${REC},${HOST},${PARTS},${COUNT},${MEDIA},${START_TIME_HR},${DURATION}s,${BRIDGE},${END_REASON}"

mkdir -p "$(dirname "$CSV")"

# Serialize concurrent writers. Many conference legs can BYE at the same instant,
# and Kamailio fires one conf-cdr-logger.sh per BYE. The read → prepend → rewrite
# → mv sequence below is NOT atomic: without a lock, two racing writers each read
# the same old file and the second mv clobbers the first's freshly-added row,
# silently dropping CDR rows.
_CSV_DIR="$(dirname "$CSV")"
if command -v flock >/dev/null 2>&1; then
    # Preferred: kernel-managed exclusive advisory lock. Blocks until acquired and
    # is released automatically when fd 9 closes — including on process death — so
    # there is no stale-lock risk and no timeout to mis-trip under heavy load.
    exec 9>"${_CSV_DIR}/.conf_cdr.lock"
    flock 9
else
    # Portable fallback (no flock available): atomic mkdir() mutex. mkdir succeeds
    # for exactly one racer; the rest spin until the holder's EXIT trap removes it.
    # The deadline is a last-resort reclaim of a lock left by a CRASHED writer; it
    # is set well above the worst-case drain time of a healthy queue (the critical
    # section is a few ms) so it never trips during legitimate contention.
    LOCKDIR="${_CSV_DIR}/.conf_cdr.lock.d"
    _lock_deadline=$(( $(date +%s) + 60 ))
    until mkdir "$LOCKDIR" 2>/dev/null; do
        if [ "$(date +%s)" -ge "$_lock_deadline" ]; then
            rmdir "$LOCKDIR" 2>/dev/null || true
            mkdir "$LOCKDIR" 2>/dev/null || true
            break
        fi
        sleep 0.02
    done
    trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM
fi

# Retention cutoff as a DATE STRING (YYYY-MM-DD), computed with a SINGLE date call.
# The critical section must be fast — it runs under the lock on every BYE — so we
# must NOT spawn `date -d` per row (that O(n) subprocess storm makes the section
# slow enough to blow the lock deadline under load and drop rows). StartTime (col 6)
# is "YYYY-MM-DD HH:MM:SS"; ISO dates compare chronologically as plain strings, so a
# lexicographic `>=` on the date prefix is a correct, subprocess-free retention test.
CUTOFF_DATE=$(date -d "$RETAIN_DAYS days ago" +%Y-%m-%d 2>/dev/null)
[ -z "$CUTOFF_DATE" ] && CUTOFF_DATE="0000-00-00"

TMP=$(mktemp)

# 1) header, 2) the new (newest) record on top
{
    echo "$HEADER"
    echo "$NEW_LINE"
} > "$TMP"

# 3) existing rows underneath, preserving their (already newest-first) order,
#    dropping the old header and any row whose StartTime (col 6) is older than
#    the retention cutoff.
if [ -f "$CSV" ]; then
    awk -F',' -v cut="$CUTOFF_DATE" -v hdr="$HEADER" '
        $0 == hdr { next }                       # skip a previously written header
        {
            d = substr($6, 1, 10)                # "YYYY-MM-DD" prefix of StartTime
            # fail-open on non-date values; otherwise keep rows within the window
            if (d !~ /^[0-9][0-9][0-9][0-9]-/ || d >= cut) { print $0 }
        }
    ' "$CSV" >> "$TMP"
fi

mv "$TMP" "$CSV"
chmod 0644 "$CSV" 2>/dev/null
