#!/bin/bash
# Strip /TYPE=PLMN@hostname — extract pure MSISDN
RAW="$1"
MSISDN="${RAW%%/*}"
MSISDN="${MSISDN%%@*}"

LOCATION_FILE="/tmp/mms-storage/current_location.tsv"

# Roaming-aware routing: current location is the ONLY source of truth now.
# location_listener.py replicates every REGISTER-driven location update to
# EVERY NIB (see nib_registry.conf), so this local copy is independently
# authoritative -- no per-MSISDN "home" mapping needed, and no dependency on
# any other NIB being reachable. If we've never seen this MSISDN register
# anywhere yet (file missing, or no row for it), default to delivering here.
if [ -r "$LOCATION_FILE" ]; then
    CURRENT_NIB="$(awk -F'\t' -v m="$MSISDN" '$1==m{ip=$2} END{if(ip!="") print ip}' "$LOCATION_FILE")"
    if [ -n "$CURRENT_NIB" ]; then
        echo "$CURRENT_NIB"
        exit 0
    fi
fi

echo "${MMSC_IP}"
exit 0
