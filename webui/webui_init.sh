#!/bin/bash
set -euo pipefail

if [[ -z "${MONGO_IP:-}" ]]; then
    echo "Error: MONGO_IP environment variable not set"
    exit 1
fi

export DB_URI="${DB_URI:-mongodb://${MONGO_IP}/open5gs}"
export HOSTNAME="${HOSTNAME:-0.0.0.0}"
export PORT="${PORT:-9999}"

cd /open5gs/webui
exec npm run dev
