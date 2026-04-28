#!/bin/bash
# Strip /TYPE=PLMN@hostname — extract pure MSISDN
RAW="$1"
MSISDN="${RAW%%/*}"
MSISDN="${MSISDN%%@*}"

REGISTRY="/etc/mmsc/nib_registry.conf"

while IFS=: read -r NIB_NUM NIB_IP RANGE_START RANGE_END; do
    [[ "$NIB_NUM" =~ ^#.*$ ]] && continue
    [[ -z "$NIB_NUM" ]] && continue

    # Check if MSISDN falls within this NIB's range
    if [[ "$MSISDN" -ge "$RANGE_START" && "$MSISDN" -le "$RANGE_END" ]]; then
        echo "$NIB_IP"
        exit 0
    fi
done < "$REGISTRY"

# Default to local
echo "${MMSC_IP}"
exit 0

