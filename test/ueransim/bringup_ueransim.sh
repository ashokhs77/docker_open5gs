#!/bin/bash
# Bring up UERANSIM 5G gNB + UE against the open5gs 5G core (sa-vonr-deploy).
# Converts the SKIP-only 5G RAN/UE test cases (registration, pdu_session, ngap_n2_5g,
# nas_conformance_5g session/registration evidence) into real PASS evidence.
#
# Prereqs:
#   - 5G core up:  docker compose -f sa-vonr-deploy.yaml up -d   (mongo+mysql first)
#   - UERANSIM image present:  docker pull gradiant/ueransim:3.2.6
#   - Run this script from the directory that holds gnb.yaml / ue.yaml / provision_5g_subscriber.js
#
# Containers are named nr-gnb / nr-ue (that is what feature 04 checks for).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
IMG="${UERANSIM_IMG:-gradiant/ueransim:3.2.6}"
NET="${OPEN5GS_NET:-docker_open5gs_default}"

echo "== 1/3 provision matching 5G subscriber (NumberInt-typed) =="
docker exec -i mongo mongo open5gs --quiet < "$DIR/provision_5g_subscriber.js"

echo "== 2/3 launch gNB (nr-gnb, 172.22.1.201) =="
docker rm -f nr-gnb >/dev/null 2>&1 || true
docker run -d --name nr-gnb --network "$NET" --ip 172.22.1.201 \
  --entrypoint nr-gnb -v "$DIR/gnb.yaml:/gnb.yaml" "$IMG" -c /gnb.yaml >/dev/null
sleep 5
docker logs nr-gnb 2>&1 | grep -iE "NG Setup procedure is successful|SCTP connection established" | tail -2 || echo "  (check: docker logs nr-gnb)"

echo "== 3/3 launch UE (nr-ue, 172.22.1.202) =="
docker rm -f nr-ue >/dev/null 2>&1 || true
docker run -d --name nr-ue --network "$NET" --ip 172.22.1.202 \
  --cap-add NET_ADMIN --device /dev/net/tun \
  --entrypoint nr-ue -v "$DIR/ue.yaml:/ue.yaml" "$IMG" -c /ue.yaml >/dev/null
sleep 9
docker logs nr-ue 2>&1 | grep -iE "Registration is successful|PDU Session establishment is successful|TUN interface" | tail -3 || echo "  (check: docker logs nr-ue)"
echo "UERANSIM_UP_DONE"
