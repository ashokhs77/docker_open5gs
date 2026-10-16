#!/bin/bash

HELPER="/usr/local/sbin/license_check_helper"
PIDFILE="$1"
#86400 for 24hrs monitoring
INTERVAL="${2:-86400}"

while true; do
    sleep "$INTERVAL"

    "$HELPER"
    if [ $? -ne 0 ]; then
        echo "License validation failed. Stopping Kamailio..."
        if [ -f "$PIDFILE" ]; then
            KPID=$(cat "$PIDFILE")
            kill -TERM "$KPID"
	    sleep 5

	if kill -0 "$KPID" 2>/dev/null; then
    	   echo "Kamailio did not stop; forcing termination"
           kill -KILL "$KPID"
	fi
        fi
        exit 1
    fi

    echo "Periodic license recheck passed"
done
