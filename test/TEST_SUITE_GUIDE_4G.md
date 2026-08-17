# 4G EPC + IMS Test Suite — Developer Guide

Comprehensive integration test suite for the **4G EPC + IMS (VoLTE/ViLTE)** side of
the `docker_open5gs` deployment. It validates EPC health, HSS/AUC authentication,
attach/PDN/bearer lifecycle, the full IMS signalling chain (P/I/S‑CSCF, FreeSWITCH,
RTPEngine), VoLTE/ViLTE calls, SMS/MMS (intra‑ and inter‑NIB, plus store‑and‑forward),
conference, CDR, capacity/load/stress, security posture, and an opt‑in TRL8
conformance/assurance block.

> **Quick reference:** see `TEST_SUITE_README_4G.txt` for a command cheat‑sheet.
> This guide is the complete reference.

---

## 1. Current status (last validated 2026‑07‑06)

| | Value |
|---|---|
| Feature groups | **34** (22 core + 12 TRL8) |
| Total test cases | **403** |
| Last full‑bundle result | **326 PASS / 1 FAIL / 76 SKIP** (the 1 fail was a transient multi‑UE registration timeout that passes on re‑run) |
| Test runner image | `docker_test` (built from `test/Dockerfile`) |
| Compose file | `test/docker-compose.test.yaml` |
| Compose service | `sipp-test` |
| 4G UE simulator | Python EPS/NAS/S1AP/SIP sim in `test/ue_sim/` (baked into the image — nothing to pull) |

The 76 skips are **by design** (no analog/FXO hardware, no external NIB, LI/Charging
presence‑audits that build no capability, and REAL_HW‑gated conformance points).

---

## 2. Prerequisites

**⚠ Required first — enable `WITH_SIPP_TEST` on the P-CSCF.** The suite drives the IMS with
synthetic SIPp/Python UE clients that skip the full IPSec/Sec-Agree handshake a real UE
performs; the `#!define WITH_SIPP_TEST` macro turns on the matching test-client bypasses in
the P-CSCF REGISTER/MO/MT routes. **Without it the VoLTE/ViLTE/SMS/conference SIPp tests
4xx-fail or hang.** It is enabled (uncommented) at `pcscf/kamailio_pcscf.cfg:20` in this test
branch — verify before bringing the stack up (uncomment it if needed; if you enable it after
the stack is already up, apply with `sudo docker restart pcscf`):

```bash
cd ~/docker_open5gs && grep -n '^#!define WITH_SIPP_TEST' pcscf/kamailio_pcscf.cfg   # must print a match
```

1. **The 4G stack must be running** (`4g-volte-deploy.yaml`): mme, sgwc, sgwu, smf, upf,
   pcscf, icscf, scscf, pyhss, mysql, dns, freeswitch, rtpengine, smsc, (mmsc). Bring it up with:
   ```bash
   cd ~/docker_open5gs
   sudo docker compose -f 4g-volte-deploy.yaml up -d
   ```
2. **The test runner image must be built** — see §3.
3. Run all test commands from the `test/` directory:
   ```bash
   cd ~/docker_open5gs/test
   ```
4. `sudo` is shown throughout; it is not required if your user is in the `docker` group.

---

## 3. How to build

There are **two independent builds**. The deployment build does **not** build the test tooling.

### 3a. Deployment images (the 4G core + IMS)
```bash
cd ~/docker_open5gs
sudo bash build_all.sh
```

### 3b. Test‑suite runner image (developer‑only)
```bash
cd ~/docker_open5gs/test
sudo bash build_test.sh            # full clean build of docker_test  [default]
sudo bash build_test.sh --cache    # fast incremental rebuild (reuse layer cache)
sudo bash build_test.sh --help
```
`build_test.sh` produces the `docker_test` image from `test/Dockerfile`. The 4G UE
simulator (`test/ue_sim/`, Python) is baked into the image and also volume‑mounted at
runtime for live edits, so there is **no separate simulator image to pull** (unlike 5G's
UERANSIM).

Equivalent raw compose build (if you prefer):
```bash
sudo docker compose -f docker-compose.test.yaml build            # cached
sudo docker compose -f docker-compose.test.yaml build --no-cache # clean
```

---

## 4. How to get help / list tests

```bash
# Show usage, all features, all bundles, examples:
sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --help

# Full catalog — every feature and every test case with its purpose:
sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --list
```
`--list` is the **live source of truth** for what exists in your current tree.

---

## 5. How to run tests

All invocations follow the same shape:
```bash
sudo docker compose -f docker-compose.test.yaml run --rm sipp-test [ARGS]
```
`--rm` auto‑removes the one‑shot runner container when the run ends.

### 5a. A single test case
```bash
sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --feature cdr --test 3
```
`--test N` requires `--feature` and runs only that one case.

### 5b. One feature group
```bash
sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --feature volte
sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --feature regression
sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --feature perf_kpi   # a TRL8 feature
```
See the feature keys in §7.

### 5c. A curated bundle
```bash
sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --bundle tec    # 22 core evidence features + TEC gap matrix
sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --bundle trl8   # the 12 TRL8 add-on features only
sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --bundle all    # everything (34 features / 403 TCs)
```

### 5d. The default core run (no arguments)
```bash
sudo docker compose -f docker-compose.test.yaml run --rm sipp-test
```
Runs the **core** feature set (the 22 core features); the TRL8 add‑on is excluded.

### 5e. The complete suite
```bash
sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --bundle all
```
This is the full release‑validation run. It auto‑provisions test subscribers, runs all
34 features (load/stress are ordered late to avoid flooding evidence used by grep‑based
conformance tests), and — because it is `--bundle all` — also generates the
**comprehensive report** (see §9). Expect ~2 hours on the reference VM.

---

## 6. How to stop a run in progress

- **Foreground run:** press `Ctrl‑C` in the terminal. With `--rm` the runner container is
  removed on exit.
- **If a runner container lingers** (or you launched it detached / named):
  ```bash
  sudo docker ps --filter ancestor=docker_test          # find it
  sudo docker rm -f <container-id-or-name>               # stop + remove
  ```
- **Sweep any orphaned runner:**
  ```bash
  sudo docker compose -f docker-compose.test.yaml down --remove-orphans
  ```

> Some features (`regression` TC‑41, `ha_resilience`) **intentionally restart core NFs**
> (pcscf, mme, …). If you stop mid‑restart, verify the stack is healthy again before the
> next run: `sudo docker ps` and `sudo docker exec pcscf kamcmd core.version`.

---

## 7. Feature catalog

### Core features (22) — default run + `--bundle tec` + `--bundle all`

| key | group | TCs | what it covers |
|---|---|---:|---|
| `epc_health` | EPC Health | 20 | EPC/IMS container + interface health — **runs first** |
| `hss_auc` | HSS AUC Auth | 12 | HSS/AUC authentication, SQN, IMS AKA, live Attach Reject audit plus deployed-binary/catalog verification of 42 named causes and the future-cause fallback |
| `pdn_session` | PDN Session | 9 | PDN/APN/default‑bearer establishment |
| `pyhss_api` | PyHSS API Negative | 10 | PyHSS REST negative‑input validation (malformed IMSI/Ki/OPc/JSON → 400) |
| `attach_churn` | Attach Detach Churn | 9 | attach/detach lifecycle churn |
| `regression` | Regression | 49 | interface health + E2E regression gate (attach, register, call, mobility, NAS ciphering, PDN types, hold/resume, call‑waiting) |
| `volte` | VoLTE | 9 | VoLTE readiness + intra/inter‑NIB call routing |
| `vilte` | ViLTE | 11 | ViLTE media/control‑plane + intra/inter‑NIB |
| `eir` | EIR | 6 | EIR / subscriber + AUC + IMS provisioning |
| `sms` | SMS | 13 | SMS over IMS, intra/inter‑NIB, **store‑and‑forward** (offline recipient) |
| `inter_nib` | Inter‑NIB | 8 | shared inter‑NIB infra: I‑CSCF routing, DNS, INVITE |
| `conference` | Conference | 17 | **complete‑path** conferences (register → P‑CSCF → FreeSWITCH, R‑URI `1NNR`) incl. single **24‑audio / 8‑video** soak — each asserts **exactly N `LEG` rows** in `conf_cdr.csv`; plus conf‑factory ingress + inter‑NIB |
| `fxo_fxs` | FXO/FXS | 5 | analog/FXO‑FXS breakout (skips without hardware) |
| `mobile_ip` | Mobile‑to‑IP | 6 | same‑IMS mobile‑to‑softphone (needs `SOFTPHONE_TARGET_URI`) |
| `cdr` | CDR | 13 | VoLTE/ViLTE CDR (S‑CSCF `cdr.csv`) + **conference CDR** (FreeSWITCH‑sourced `conf_cdr.csv`): 9‑col schema, newest‑on‑top, 7‑day retention, and a real‑UE conference dial (register → P‑CSCF → FreeSWITCH) |
| `load` | Load Test | 14 | capacity ramps + data‑plane throughput/jitter |
| `mms` | MMS | 18 | MMS/Kannel/Mbuni, intra/inter‑NIB, MM7 |
| `stress` | Stress Test | 8 | stability / extreme‑condition |
| `bearer_qos` | Bearer QoS | 10 | QCI‑9/5/1/2 bearer lifecycle + Rx AAR/STR |
| `tec` | TEC Readiness | 13 | reads prior feature reports → TEC evidence/gap matrix |
| `advanced_sip` | Advanced SIP | 5 | RTP echo, DTMF, REFER, emergency, IPv6 |
| `security` | Security | 10 | auth enforcement, input validation, RFC compliance, DoS survivability |

### TRL8 conformance/assurance add‑on (12) — `--bundle trl8` + `--bundle all` (opt‑in)

| key | group | TCs | standard |
|---|---|---:|---|
| `nas_conformance` | NAS Conformance | 10 | TS 24.301 / 33.401 |
| `scas_itsar` | SCAS/ITSAR Security | 12 | TS 33.117 / 33.210 / ITSAR |
| `diameter_conformance` | Diameter Conformance | 12 | S6a/Cx/Rx — RFC 6733 / TS 29.272 |
| `pfcp_n4` | PFCP Conformance | 12 | TS 29.244 |
| `s1ap` | S1AP Conformance | 12 | TS 36.413 |
| `ims_ng114` | IMS Profile IR.92/94 | 12 | GSMA IR.92 / IR.94 |
| `perf_kpi` | Performance KPI | 12 | TS 28.554 |
| `ha_resilience` | HA / Resilience | 12 | TS 23.527 — **restarts NFs** |
| `oam_fcaps` | OAM / FCAPS | 12 | TS 28.552 / 28.545 |
| `charging` | Charging | 12 | TS 32.251 / 32.299 |
| `li_presence` | LI Readiness | 12 | TS 33.127 / 33.128 (architecture‑presence audit) |
| `interface_evidence` | Interface Evidence | 8 | TRL8 pcap/endpoint evidence (real‑HW pcap gate) |

---

## 8. Bundle catalog

| bundle | contents | use it for |
|---|---|---|
| *(no arg)* | 22 core features | dev/deployment smoke |
| `--bundle tec` | 22 core features + TEC gap matrix | strongest automated 4G+IMS evidence pack |
| `--bundle trl8` | 12 TRL8 features only | conformance/assurance pass |
| `--bundle all` | 34 features (core + TRL8) + comprehensive report | full release validation |

---

## 9. Reports

Reports are written **inside the runner** at `/opt/test/reports/` (bind‑mounted to the host —
see `volumes:` in `docker-compose.test.yaml`, typically `test/reports/`).

| file | contents |
|---|---|
| `summary.txt` | feature totals table (total/pass/fail/skip) — the quick green/red check |
| `detailed_test_report.txt` | full human‑readable report: hardware, per‑test results, failures, skips, limitations |
| `<feature>.txt` | raw per‑feature PASS/FAIL/SKIP lines with reason/error detail |
| `hardware_resource_report.txt`, `hardware_checkpoints.csv` | per‑feature cgroup memory‑peak / CPU‑time / I/O |
| `tec_certification_gap_matrix.txt` | from `--feature tec` / `--bundle tec` |
| `comprehensive/TEST_REPORT_4G_latest.{md,html,json}` | **only on `--bundle all`** — 10‑section per‑stack report incl. Core‑IMS KPI matrix with E‑model MOS |

---

## 10. Interpreting results

- **PASS** — the automated path worked in this lab run.
- **FAIL** — a behaviour/threshold/dependency/evidence check failed; fix before calling the suite green.
- **SKIP** — an optional dependency or real‑HW/manual lane is not present. Not a failure, but a coverage gap.

**Expected by‑design skips** in the default deployment:
- `fxo_fxs` (5) and `mobile_ip` (6) — need physical analog gateways / a softphone target.
- `li_presence` (mostly) — presence audit; builds no interception capability by design.
- `charging`, `scas_itsar`, conformance features — partial: OCS/CGF/CHF absent, some open5gs paths are debug‑only, REAL_HW‑gated evidence.
- IPv6 PDN cases — depend on an IPv6 UE pool in `smf.yaml`.
- Load/capacity — report the achieved ceiling as PASS above a functional floor; the AVX‑less reference VM is CPU‑bound well below the 128/512 targets.

**Flaky vs. real:** the multi‑UE supplemental tests (e.g. Regression TC‑35 call‑waiting) can
time out transiently in the window right after the harness restarts pcscf+mme back‑to‑back.
Re‑run the single feature (`--feature regression`) to confirm before treating it as a real failure.

---

## 11. Configuration prerequisites (Core/IMS macros)

The suite assumes the test‑enabled IMS profile. If you move to a production profile or merge
another branch, verify these before a release/TEC run:

**P‑CSCF** (`pcscf/pcscf.cfg`, `pcscf/kamailio_pcscf.cfg`):
- `#!define WITH_SIPP_TEST` — synthetic SIPp/UE test‑client handling in REGISTER/MO/MT.
- `#!define WITH_FREESWITCH`, `WITH_RX`, `WITH_IPSEC`, `WITH_TCP`, `FORCE_RTPRELAY`, `WITH_PING_UDP/TCP`.
- `#!define IPSEC_MAX_CONN 30` — sized for a 24‑UE VoLTE conference (+ headroom). **Do not drop to 20.**
- `children=8` — with `open_files_limit=65536`. This is deliberate: `children` × `(2·IPSEC_MAX_CONN+1)` forks must keep the CDP Diameter (Rx) socket fd **< 1024**, or `select()` breaks the Rx peer. Keep the rule `children*(2*IPSEC_MAX_CONN+1)+overhead < 1024`.
- `modparam("ims_qos","authorize_video_flow",1)` — ViLTE/QCI‑2.
- **Conference CDR (FreeSWITCH‑sourced)**: conference dials (`1NNR`) route P‑CSCF → FreeSWITCH (never via the S‑CSCF). The conference bridge lives on the host NIB's **FreeSWITCH**, which is now the **single source** of the CDR: a `mod_lua` script (`conference_cdr.lua`) consumes `conference::maintenance` events and writes each participant's `LEG` row (on leave) plus the `CONF` summary (on destroy) to `/cdr-logs/conf_cdr.csv` via the shared `conf-cdr-logger.sh` (host `/var/log/kamailio/`) — 9‑col schema, newest‑on‑top, `kamailio-conf-cdr` logrotate. Because the bridge sees **every** member — including participants relayed in from other NIBs — the host‑NIB CDR is complete for inter‑NIB conferences. (The old P‑CSCF `confcdr` htable/`exec.so` path is compiled out via `WITH_PCSCF_CONF_CDR`, kept only as a single‑NIB fallback.)

**S‑CSCF** (`scscf/scscf.cfg`, `scscf/kamailio_scscf.cfg`):
- `#!define WITH_TCP`, `WITH_AUTH`.
- CDR route/htable/logging (`/cdr-logs/cdr.csv` + logrotate) for VoLTE/ViLTE CDR. (Conference CDR is on the P‑CSCF — see above.)
- USER_ONLINE active‑presence branch + inter‑NIB MESSAGE routing for SMS store‑and‑forward and inter‑NIB SMS.

---

## 12. Directory layout (`test/`)

```
Dockerfile                     builds docker_test (the runner)
docker-compose.test.yaml       the sipp-test service definition
build_test.sh                  developer build of docker_test
run_tests.sh                   entrypoint: --feature/--test/--bundle/--list/--help
provision_subscribers.sh       seeds test APNs/AUC/subscriber/IMS rows in PyHSS/MySQL
lib/                           common.sh (framework), sipp_helpers.sh, comprehensive_report.py
features/                      NN_<feature>.sh — one script per feature group (incl. TRL8 20..29)
scenarios/                     SIPp XML scenarios used by the feature scripts
ue_sim/                        Python EPS/NAS/S1AP/SIP UE simulator (Milenage AKA, TAU, SQN resync)
reports/                       generated reports (bind-mounted to the runner's /opt/test/reports)
```

---

## 13. Troubleshooting

| symptom | fix |
|---|---|
| Runner exits immediately, "service not available" | The 4G stack isn't up/healthy. `sudo docker compose -f 4g-volte-deploy.yaml up -d`, then check `pcscf`, `mme`, `pyhss`. |
| pcscf `Connection refused` on `kamcmd` right after a restart | It forks ~530 workers — wait ~20 s. Confirm the Rx peer with `sudo docker exec pcscf kamcmd cdp.list_peers` (want `I_Open`). |
| pyhss_api negative TCs fail on a fresh build | The apiService.py validation patch must be present — it is overlaid via `COPY services/apiService.py` in `pyhss/Dockerfile`. Rebuild pyhss. |
| Whole suite hangs at Regression | A dead pcscf with no timeout — the health checks now have `timeout` guards; verify pcscf is healthy. |
| Load/capacity numbers lower than targets | Expected on the AVX‑less reference VM (CPU‑bound); the tests report the achieved ceiling as PASS above a functional floor. |
