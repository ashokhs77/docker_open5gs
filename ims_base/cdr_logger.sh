#!/bin/bash

# This script writes formatted CDR log entries to /cdr-logs/cdr.log
# It expects 6 arguments in this order:
# 1. Call-ID
# 2. From URI
# 3. To URI
# 4. Call Type (audio/video)
# 5. Start time (epoch)
# 6. Duration (seconds)

CALL_ID="$1"
FROM_URI="$2"
TO_URI="$3"
CALL_TYPE="$4"
START_EPOCH="$5"
DURATION="$6"

# Guard: never write a row that is not a complete CDR. A missing argument shifts every
# later column (caller missing -> "callee,audio,<epoch>,1970-01-01 00:00:10,s"), and
# such a row cannot be repaired afterwards. Refusals go to syslog, not to the CSV.
reject() {
    logger -t cdr-logger "row refused ($1): [$CALL_ID] [$FROM_URI] [$TO_URI] [$CALL_TYPE] [$START_EPOCH] [$DURATION]" 2>/dev/null
    exit 0
}
[ "$#" -eq 6 ] || reject "expected 6 arguments, got $#"
[ -n "$FROM_URI" ] && [ -n "$TO_URI" ] || reject "empty caller or callee"
case "$CALL_TYPE" in audio|video) ;; *) reject "call type is not audio/video" ;; esac
case "$START_EPOCH" in ''|*[!0-9]*) reject "start time is not an epoch" ;; esac
case "$DURATION" in ''|*[!0-9]*) reject "duration is not a number" ;; esac
case "$FROM_URI$TO_URI" in *,*) reject "comma in caller or callee" ;; esac

# Format the start time as human-readable datetime
START_TIME_HR=$(date -d "@$START_EPOCH" '+%Y-%m-%d %H:%M:%S') || reject "start time not convertible"

# Append to the log file
#echo "CDR_LOG: Call-ID=$CALL_ID From=$FROM_URI To=$TO_URI Type=$CALL_TYPE Start=$START_TIME_HR Duration=${DURATION}s" >> /cdr-logs/cdr.log
echo "$FROM_URI,$TO_URI,$CALL_TYPE,$START_TIME_HR,${DURATION}s" >> /cdr-logs/cdr.csv

