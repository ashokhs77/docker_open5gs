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

# Format the start time as human-readable datetime
START_TIME_HR=$(date -d @$START_EPOCH '+%Y-%m-%d %H:%M:%S')

# Append to the log file
#echo "CDR_LOG: Call-ID=$CALL_ID From=$FROM_URI To=$TO_URI Type=$CALL_TYPE Start=$START_TIME_HR Duration=${DURATION}s" >> /cdr-logs/cdr.log
echo "$FROM_URI,$TO_URI,$CALL_TYPE,$START_TIME_HR,${DURATION}s" >> /cdr-logs/cdr.csv

