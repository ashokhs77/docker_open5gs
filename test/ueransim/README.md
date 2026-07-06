# UERANSIM 5G gNB + UE (software RAN/UE simulator)

Drives the open5gs **5G** core (sa-vonr-deploy) with a simulated gNB + UE so the
RAN/UE-dependent test cases produce **real PASS evidence** instead of SKIP.
This is the 5G counterpart to the 4G `test/ue_sim` (4G already has its RAN/UE sim).
It is a **software** simulator — functional/protocol coverage, *not* the real-HW
tier (RF, real USIM, handover). Real-HW scenarios stay gated behind `REAL_HW=1`.

## What it lights up (verified 2026-06-11)
- `registration` (04): NG Setup, Reg Request/Accept, UE context (~8 PASS)
- `ngap_n2_5g` (22): NG Setup, Initial UE Message, RAN/AMF_UE_NGAP_ID, UE Context
  Release, SCTP multi-streaming — 2 PASS → **7 PASS**
- `nas_conformance_5g` (18): Registration Accept+GUTI, De-registration, Reject cause
  — 4 PASS → **7 PASS**
- `pdu_session` (05) data-plane; UE gets a real IP on `uesimtun0`
- Remaining SKIPs (5G-AKA, Security-Mode, PDU-Session-Resource, PFCP-session) are
  open5gs INFO-verbosity limits — the procedures run but aren't logged greppably.

## Prerequisites
1. 5G core up (`sa-vonr-deploy.yaml`), mongo+mysql first.
2. UERANSIM image: `docker pull gradiant/ueransim:3.2.6`  (309 MB; no cmake needed on host).

## Usage
This folder lives in the test tree at `test/ueransim/` (the 5G counterpart to `test/ue_sim/`),
so it ships with the test suite — on the VM it is `/home/lekha/docker_open5gs_5g/test/ueransim/`.
It is host-side tooling: `bringup_ueransim.sh` runs on the VM host (not inside the test container)
and spawns sibling `nr-gnb`/`nr-ue` containers on the `docker_open5gs_default` network, which the
5G test features then detect via the docker socket. From that folder run:
```bash
bash bringup_ueransim.sh        # provisions subscriber, starts nr-gnb + nr-ue
# verify:
docker logs nr-ue | grep -iE "Registration is successful|TUN interface"
docker exec nr-ue ip addr show uesimtun0   # 10.45.0.2/32
# tear down:
docker rm -f nr-gnb nr-ue
```
Then re-run the 5G suite (`--feature registration`, `--feature ngap_n2_5g`, `--bundle trl8`, …).

## Gotchas baked into these files (learned the hard way)
- **Subscriber integers MUST be `NumberInt()`** (see provision_5g_subscriber.js). The
  legacy mongo:4.4 shell stores JS numbers as double; open5gs DBI reads int32, so
  doubles cause UDR `No SST`/`No UE-AMBR` → AMF reject cause #7 (5GS services not allowed).
- **S-NSSAI must match amf.yaml** `plmn_support` (first entry = `sst:1, sd:000001`).
  gNB, UE, and subscriber all use `sst:1 / sd:000001`.
- UE needs `--cap-add NET_ADMIN --device /dev/net/tun` to create `uesimtun0`.
- Bypass the gradiant entrypoint with `--entrypoint nr-gnb` / `nr-ue` to use these
  static configs (the default entrypoint does env-var templating instead).
- Static IPs on `docker_open5gs_default`: gNB 172.22.1.201, UE 172.22.1.202
  (test container uses .200). AMF N2 = 172.22.1.10:38412.
