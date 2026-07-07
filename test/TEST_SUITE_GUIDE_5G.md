# 5G SA + VoNR Test Suite — Developer Guide

Comprehensive integration test suite for the **5G SA core + VoNR (IMS)** side of the
`docker_open5gs` deployment. It validates the 5GC (amf/ausf/bsf/nrf/nssf/pcf/scp/udm/udr,
smf, upf), the SBI mesh, AKA/registration, PDU sessions and QoS flows, network slicing,
VoNR/ViNR over the shared IMS, SMS/MMS over 5GS, CDR, capacity/load/stress, security
posture, and an opt‑in TRL8 conformance/assurance block.

Unlike the 4G suite, most RAN/UE‑dependent tests need **UERANSIM** (a software 5G gNB+UE)
running against the core — see §3b and §4.

> **Quick reference:** see `TEST_SUITE_README_5G.txt` for a command cheat‑sheet.
> This guide is the complete reference.

---

## 1. Current status (last validated 2026‑07‑06)

| | Value |
|---|---|
| Feature groups | **31** (19 core + 12 TRL8) |
| Total test cases | **366** |
| Last full‑bundle result | **307 PASS / 2 FAIL / 57 SKIP** (both fails were transient load‑generator PDU‑ceiling TCs that pass on a clean re‑run) |
| Test runner image | `docker_test_5g` (built from `test/Dockerfile.5g`) |
| Compose file | `test/docker-compose.test5g.yaml` |
| Compose service | `sipp-test-5g` |
| RAN/UE simulator | **UERANSIM** `gradiant/ueransim:3.2.6` — pulled, not compiled; run as `nr-gnb`/`nr-ue` |

The 57 skips are **by design** (LI presence‑audit, debug‑only conformance points,
no OCS/CHF for charging, and REAL_HW‑gated data‑plane sweeps).

---

## 2. Prerequisites

**⚠ Required first — enable `WITH_SIPP_TEST` on the (shared) P-CSCF.** VoNR/ViNR/SMS/conference
tests drive the shared IMS with synthetic SIPp UE clients that skip the full IPSec/Sec-Agree
handshake a real UE performs; the `#!define WITH_SIPP_TEST` macro turns on the matching
test-client bypasses in the P-CSCF REGISTER/MO/MT routes. **Without it those SIPp tests
4xx-fail or hang.** It is enabled (uncommented) at `pcscf/kamailio_pcscf.cfg:20` in this test
branch — verify before bringing the stack up (uncomment it if needed; if you enable it after
the stack is already up, apply with `sudo docker restart pcscf`):

```bash
cd ~/docker_open5gs && grep -n '^#!define WITH_SIPP_TEST' pcscf/kamailio_pcscf.cfg   # must print a match
```

1. **The 5G stack must be running** (`sa-vonr-deploy.yaml`):
   ```bash
   cd ~/docker_open5gs
   sudo docker compose -f sa-vonr-deploy.yaml up -d
   ```
2. **AVX‑less host? Use MongoDB 4.4.** MongoDB ≥5.0 needs AVX; on a QEMU/i440FX VM
   without it, `mongo:6.0` crashes (SIGILL, exit 132) and the UDR/PCF/BSF subscriber
   store is dead → registration fails. Fix in `~/docker_open5gs/.env`:
   ```
   MONGO_IMAGE=mongo:4.4
   ```
   then recreate mongo and **restart the mongo‑dependent NFs** (they cache the connection):
   ```bash
   sudo docker compose -f sa-vonr-deploy.yaml up -d --force-recreate mongo
   sudo docker restart pcf bsf udr udm webui
   ```
   Until PCF reconnects, AMF→PCF AM‑Policy‑Control returns HTTP 504 → Registration reject.
3. **The test runner image + UERANSIM must be built/pulled** — see §3.
4. Run all test commands from the `test/` directory: `cd ~/docker_open5gs/test`.
5. `sudo` is shown throughout; omit it if your user is in the `docker` group.

---

## 3. How to build

Two independent builds. The deployment build does **not** build the test tooling or UERANSIM.

### 3a. Deployment images (the 5G core + IMS)
```bash
cd ~/docker_open5gs
sudo bash build_all_5g.sh
```

### 3b. Test‑suite runner image + UERANSIM (developer‑only)
```bash
cd ~/docker_open5gs/test
sudo bash build_test_5g.sh                 # build docker_test_5g + ensure UERANSIM image  [default]
sudo bash build_test_5g.sh --cache         # fast incremental rebuild of the runner image
sudo bash build_test_5g.sh --only-runner   # only the docker_test_5g runner image
sudo bash build_test_5g.sh --only-ueransim # only prepare (pull) UERANSIM
sudo bash build_test_5g.sh --help
```
This produces:
1. `docker_test_5g` — the 5G test runner (from `test/Dockerfile.5g`).
2. **UERANSIM** — `gradiant/ueransim:3.2.6`. This is a **pre‑built image that is pulled**,
   not compiled from source (no cmake toolchain needed). "Building" it just means the image
   is present locally. Override the tag with `UERANSIM_IMG=<tag> sudo bash build_test_5g.sh`.

The gNB/UE run as standalone `nr-gnb` / `nr-ue` containers and are **not** part of any
deployment compose file, so they never start during a normal deployment.

---

## 4. UERANSIM — how to build and run (5G only)

The RAN/UE‑dependent tests (`registration`, `pdu_session`, `pdu_profile_5g`, `qos_flow_5g`,
`ngap_n2_5g`, `nas_conformance_5g`, UE‑plane `perf_kpi_5g`, and the `load_5g` ramps) require
a live gNB+UE. Bring UERANSIM up **after** the 5G core is healthy and **before** running the suite.

### 4a. Bring up the functional gNB + UE
```bash
cd ~/docker_open5gs/test
sudo bash ueransim/bringup_ueransim.sh
```
This (1) provisions a matching 5G subscriber in mongo/UDR, (2) launches `nr-gnb`
(172.22.1.201), and (3) launches `nr-ue` (172.22.1.202). Success looks like:
```
NG Setup procedure is successful
Initial Registration is successful
PDU Session establishment is successful PSI[1]
TUN interface[uesimtun0, 10.45.0.2] is up.
```

### 4b. Load cells (dedicated load gNBs)
The `load_5g` feature launches its own dedicated load cells (`nr-gnb-load-0/1`) and multi‑UE
generators using the configs `ueransim/{gnb_load_0,gnb_load_1,ue_load_0,ue_load_1}.yaml` and
helpers in `lib/ueransim_load_5g.sh`. You do **not** start these manually — the feature does.

### 4c. Verify UERANSIM
```bash
sudo docker ps --filter name=nr-                       # expect nr-gnb, nr-ue Up
sudo docker logs nr-ue  2>&1 | grep -E "Registration is successful|PDU Session"
```

### 4d. How to STOP UERANSIM
`nr-gnb`/`nr-ue` are standalone `docker run` containers (not compose‑managed), so remove
them by name:
```bash
sudo docker rm -f nr-ue nr-gnb                          # stop + remove functional gNB/UE
sudo docker rm -f $(sudo docker ps -aq --filter name=load) 2>/dev/null   # any lingering load cells
```
Use `docker stop nr-ue nr-gnb` instead if you want to keep them for a later restart.
Removing UERANSIM does **not** affect the 5G core.

---

## 5. How to get help / list tests

```bash
sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --help
sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --list
```
`--list` is the **live source of truth** for the current tree.

---

## 6. How to run tests

All invocations follow the same shape:
```bash
sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g [ARGS]
```

### 6a. A single test case
```bash
sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --feature vonr --test 3
```
`--test N` requires `--feature`.

### 6b. One feature group
```bash
sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --feature registration
sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --feature vonr
sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --feature ngap_n2_5g   # a TRL8 feature
```

### 6c. A curated bundle
```bash
sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --bundle 5gc    # 5 core-only smoke features — NO UERANSIM needed
sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --bundle full   # 19 core features
sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --bundle trl8   # 12 TRL8 features only
sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --bundle all    # everything (31 features / 366 TCs)
```
> **`--bundle 5gc` needs no UERANSIM** — it is health + SBI + auth + slicing only, a fast
> core smoke test. Every other bundle/feature above assumes UERANSIM is up (§4).

### 6d. The default core run (no arguments)
```bash
sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g
```
Runs the **core** feature set (the 19 core features); the TRL8 add‑on is excluded.

### 6e. The complete suite
```bash
sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --bundle all
```
Full release validation. `load_5g`, `stress_5g`, and `ha_resilience_5g` are ordered **last**
(their multi‑UE PDU churn floods SMF/UPF logs used by earlier grep‑based conformance tests,
and HA restarts NFs). Because it is `--bundle all` it also generates the **comprehensive
report** (§9).

---

## 7. How to stop a run in progress

**The test run:**
- Foreground run: press `Ctrl‑C` (with `--rm` the runner container is removed on exit).
- If a runner container lingers:
  ```bash
  sudo docker ps --filter ancestor=docker_test_5g
  sudo docker rm -f <container-id-or-name>
  ```
- Sweep orphans: `sudo docker compose -f docker-compose.test5g.yaml down --remove-orphans`

**UERANSIM** (separate from the test run — see §4d):
```bash
sudo docker rm -f nr-ue nr-gnb
sudo docker rm -f $(sudo docker ps -aq --filter name=load) 2>/dev/null
```

> `ha_resilience_5g` intentionally restarts NFs. If you stop mid‑restart, re‑verify the core
> (`sudo docker ps`) and, if the UE dropped, re‑run `bringup_ueransim.sh` before continuing.

---

## 8. Feature catalog

### Core features (19) — default run + `--bundle full` + `--bundle all`

| key | group | TCs | what it covers | needs UERANSIM |
|---|---|---:|---|:---:|
| `regression_5g` | Regression (5G) | 23 | 5GC container/interface health + E2E regression gate | some |
| `5gc_health` | 5GC Health | 20 | NF container + SBI endpoint health | no |
| `nrf_sbi` | NRF & SBI | 10 | NRF registration + SBI mesh reachability | no |
| `ausf_udm` | AUSF/UDM Auth | 8 | 5G‑AKA authentication vectors | no |
| `registration` | 5G Registration | 9 | Initial Registration over N1/N2 | **yes** |
| `pdu_session` | PDU Session | 7 | PDU session establishment (N4/PFCP) | **yes** |
| `pdu_profile_5g` | PDU Profile (5G) | 10 | DNN / IPv4v6 session profiles | **yes** |
| `vonr` | VoNR | 11 | VoNR call control over the shared IMS | some |
| `sms_5g` | SMS over 5GS | 13 | SMS over NAS / IMS, intra/inter‑NIB | some |
| `cdr_5g` | CDR (5G) | 7 | 5G CDR generation | some |
| `slicing` | Network Slicing | 7 | S‑NSSAI selection (NSSF) | no |
| `security_5g` | Security (5G) | 14 | 5G auth/input‑validation/DoS posture | some |
| `mms_5g` | MMS over 5GS | 18 | MMS/Kannel/Mbuni over 5GS | some |
| `conference_5g` | Conference (5G VoNR) | 15 | VoNR conference incl. 24‑audio/8‑video soak | some |
| `advanced_sip_5g` | Advanced SIP (5G VoNR) | 5 | RTP echo/DTMF/REFER/emergency over VoNR | some |
| `stress_5g` | Stress Test (5G VoNR) | 9 | VoNR stability under stress | **yes** |
| `video_vonr` | Video VoNR (ViNR) | 10 | video VoNR (ViNR) call flows | some |
| `qos_flow_5g` | QoS Flow (5G) | 10 | 5QI flow lifecycle (5QI‑9/5/1/2) | **yes** |
| `load_5g` | Load Test (5G) | 20 | registration/PDU/burst ramps (128/256/512 sharded) + VoNR INVITE | **yes** |

### TRL8 conformance/assurance add‑on (12) — `--bundle trl8` + `--bundle all` (opt‑in)

| key | group | TCs | standard |
|---|---|---:|---|
| `nas_conformance_5g` | NAS Conformance (5G) | 12 | TS 24.501 |
| `scas_itsar_5g` | SCAS/ITSAR Security (5G) | 12 | TS 33.117 / 33.512 / 33.515 / ITSAR |
| `sbi_conformance_5g` | SBI Conformance (5G) | 12 | TS 29.500 / 29.501 |
| `pfcp_n4_5g` | PFCP/N4 Conformance (5G) | 12 | TS 29.244 |
| `ngap_n2_5g` | NGAP/N2 Conformance (5G) | 12 | TS 38.413 |
| `ims_ng114_5g` | IMS Profile NG.114 (5G) | 12 | GSMA NG.114 |
| `perf_kpi_5g` | Performance KPI (5G) | 12 | TS 28.554 |
| `ha_resilience_5g` | HA / Resilience (5G) | 12 | TS 23.527 — **restarts NFs** |
| `oam_fcaps_5g` | OAM / FCAPS (5G) | 12 | TS 28.552 / 28.545 |
| `charging_5g` | Charging (5G) | 12 | TS 32.255 / 32.290 |
| `li_presence_5g` | LI Readiness (5G) | 12 | TS 33.127 / 33.128 (architecture‑presence audit) |
| `interface_evidence_5g` | Interface Evidence (5G) | 8 | TRL8 pcap/endpoint evidence |

---

## 9. Bundle catalog

| bundle | contents | UERANSIM | use it for |
|---|---|:---:|---|
| `--bundle 5gc` | 5 core smoke features (health/SBI/auth/slicing) | **no** | fast 5GC sanity |
| *(no arg)* | 19 core features | yes | core validation |
| `--bundle full` | 19 core features | yes | core validation |
| `--bundle trl8` | 12 TRL8 features | yes | conformance/assurance |
| `--bundle all` | 31 features + comprehensive report | yes | full release validation |

---

## 10. Reports

Written inside the runner at `/opt/test/reports/` (bind‑mounted to the host).

| file | contents |
|---|---|
| `summary.txt` | feature totals (total/pass/fail/skip) |
| `detailed_test_report.txt` | full human‑readable report (hardware, results, skips, limitations) |
| `<feature>.txt` | per‑feature PASS/FAIL/SKIP + reason/error |
| `comprehensive/TEST_REPORT_5G_latest.{md,html,json}` | **only on `--bundle all`** — 10‑section report incl. Core‑IMS KPI matrix with E‑model MOS |

---

## 11. Interpreting results

- **PASS / FAIL / SKIP** — as for 4G (see the 4G guide §10). Fix FAILs; SKIPs are coverage gaps, not failures.

**Expected by‑design skips:**
- `li_presence_5g` (mostly) — presence audit, builds no interception capability.
- `charging_5g`, `scas_itsar_5g`, conformance features — partial: no OCS/CHF, some open5gs paths debug‑only, REAL_HW‑gated evidence.
- Data‑plane line‑rate sweeps — REAL_HW‑gated (UERANSIM userspace GTP‑U cannot sustain bulk throughput).

**The load feature is UERANSIM‑bound and variable.** The 5G core sustains 512 UEs + PDU at
~0% CPU; the ceiling is the **UERANSIM per‑process limit** on the host, not the core. So ~1–2
of the 20 `load_5g` TCs can flip PASS/FAIL run‑to‑run (a *different* TC each time — e.g. TC‑9
registration at N=128, or TC‑12/16 PDU capacity showing 0 after a prior 256‑UE ramp left
SMF/UPF session state). To confirm one is transient, flush state and re‑run the feature:
```bash
sudo docker restart smf upf ; sleep 10 ; sudo docker restart nr-gnb nr-ue ; sleep 12
sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --feature load_5g
```

---

## 12. Directory layout (5G‑specific bits under `test/`)

```
Dockerfile.5g                    builds docker_test_5g (the 5G runner)
docker-compose.test5g.yaml       the sipp-test-5g service definition
build_test_5g.sh                 developer build of docker_test_5g + UERANSIM pull
run_tests_5g.sh                  entrypoint: --feature/--test/--bundle/--list/--help
features/5g/                      NN_<feature>_5g.sh — one script per 5G feature group
lib/ueransim_load_5g.sh          multi-UE load-cell helpers for load_5g
lib/comprehensive_report.py      shared report generator (4G + 5G)
ueransim/
  bringup_ueransim.sh            provisions a subscriber + launches nr-gnb / nr-ue
  gnb.yaml / ue.yaml             functional gNB / UE configs
  gnb_load_0.yaml / gnb_load_1.yaml   dedicated load-cell gNB configs
  ue_load_0.yaml / ue_load_1.yaml     load-cell UE configs
  provision_5g_subscriber.js     single-subscriber provisioner (mongo/UDR)
  provision_5g_range.js          range provisioner for load tests
```

---

## 13. Typical end‑to‑end run (from scratch)

```bash
# 1) core up (with the mongo:4.4 workaround already in .env on AVX-less hosts)
cd ~/docker_open5gs
sudo docker compose -f sa-vonr-deploy.yaml up -d
sudo docker restart pcf bsf udr udm webui          # ensure NFs picked up mongo

# 2) build test tooling + UERANSIM (once)
cd ~/docker_open5gs/test
sudo bash build_test_5g.sh

# 3) bring up UERANSIM (gNB + UE)
sudo bash ueransim/bringup_ueransim.sh

# 4) run the complete suite
sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --bundle all

# 5) tear down UERANSIM when done
sudo docker rm -f nr-ue nr-gnb
```

---

## 14. Troubleshooting

| symptom | fix |
|---|---|
| Registration rejects / UDR empty | MongoDB AVX crash on this host — set `MONGO_IMAGE=mongo:4.4`, recreate mongo, restart `pcf bsf udr udm webui` (§2). |
| webui :9999 not reachable (`ausf_udm` TC) | webui crashed its mongo connect — `sudo docker restart webui`. |
| `registration`/`pdu_session` all SKIP or FAIL | UERANSIM isn't up — run `bringup_ueransim.sh` and confirm `nr-ue` registered (§4c). |
| `load_5g` shows 0 PDU / low reg at high N | UERANSIM per‑process ceiling on this host, and/or SMF/UPF session‑state accumulation — flush and re‑run the feature (§11). |
| HA test left the stack disturbed | re‑verify the core and re‑run `bringup_ueransim.sh` (§7). |
