#!/bin/bash
# Smoke-test: verify mongo_eval() auto-detects mongo vs mongosh
set +e
source /home/lekha/docker_open5gs/test/lib/common_5g.sh

echo "=== mongo shell detection ==="
_detect_mongo_shell
echo "Detected shell: $_MONGO_SHELL"

echo ""
echo "=== ping test ==="
result=$(mongo_eval "" 'db.runCommand({ping:1}).ok')
echo "Ping result: $result"

echo ""
echo "=== open5gs subscriber count ==="
count=$(mongo_eval "open5gs" 'db.subscribers.countDocuments()')
echo "Subscriber count: $count"

echo ""
echo "=== database list ==="
dbs=$(mongo_eval "" 'db.adminCommand({listDatabases:1}).databases.map(d=>d.name).join(",")')
echo "Databases: $dbs"

echo ""
if [ "$result" = "1" ]; then
    echo "SMOKE PASS: mongo_eval works with $_MONGO_SHELL"
else
    echo "SMOKE FAIL: ping returned '$result' instead of 1"
    exit 1
fi
