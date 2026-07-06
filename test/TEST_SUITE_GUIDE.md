# Integration Test Suite — Guide (4G EPC+IMS & 5G SA+IMS)

A single test framework validates two deployments on the same host:

- **4G** — open5gs EPC (MME/SGW-C/U, SMF/UPF) + Kamailio IMS (P/I/S-CSCF) + FreeSWITCH + PyHSS + MySQL + MMSC, driven from `run_tests.sh`.
- **5G** — open5gs 5G SA (AMF/SMF/UPF/NRF/AUSF/UDM/UDR/PCF/NSSF/BSF/SCP) + the **shared** IMS + MongoDB (UDR), driven from `run_tests_5g.sh`; UERANSIM is test-suite-only and is started separately for UE/RAN-dependent tests.

Current catalog size: **4G has 34 feature groups** (22 default core + 12 opt-in TRL8) and **5G has 30 feature groups** (18 full/core + 12 opt-in TRL8). Runtime `--list` and `summary.txt` are authoritative for exact test-case totals.

---

## 1. Prerequisites

- Docker + docker compose, ~8 vCPU / 14 GiB (the validated host is 8c/14G).
- Built deployment images: `docker_open5gs` (NFs) and the IMS/infra images. For test runs, separately build `docker_test`/`docker_test_5g`; the 5G test build also pulls `gradiant/ueransim:3.2.6`.
- `.env` with the host-specific `DOCKER_HOST_IP` (each host differs — do not copy between hosts).

## 2. Build

```bash
# from docker_open5gs/
./build_all.sh                 # 4G deployment images only
./build_all_5g.sh              # 5G deployment images only

# Developer-only test-suite images are deliberately separate:
sudo bash test/build_test.sh      # 4G test runner image
sudo bash test/build_test_5g.sh   # 5G test runner image + UERANSIM pull
```
Test scripts/scenarios/configs are **bind-mounted** into the runner (`./lib`, `./features`, `./scenarios`, `./ueransim` → `/opt/test/...`), so editing a test takes effect on the next run **without a rebuild**.

## 3. Launch a stack

**4G — single command:**
```bash
sudo docker compose -f 4g-volte-deploy.yaml up -d
```

**5G — single command (same as 4G):**
```bash
sudo docker compose -f sa-vonr-deploy.yaml up -d
```
The 5GC NFs tolerate a not-yet-ready datastore (they retry their mongo/mysql connection), so one `up -d` brings the whole stack up cleanly — verified: all 25 containers running, none crashed. No pre-step and no wrapper script are needed. (Edge case: on a brand-new deployment with *empty* DB volumes, if a couple of NFs race mongo's first-time init, just run `up -d` once more.)

**5G test-suite RAN/UE (not part of normal deployment; only needed for live registration/PDU/VoNR + load tests):**
```bash
cd test/ueransim && ./bringup_ueransim.sh      # nr-gnb + nr-ue against the live 5GC
```

## 4. Run the suite

The runner executes inside the test container via `docker compose run`:

```bash
# 4G
sudo docker compose -f test/docker-compose.test.yaml  run --rm sipp-test     [OPTIONS]
# 5G
sudo docker compose -f test/docker-compose.test5g.yaml run --rm sipp-test-5g [OPTIONS]
```

`[OPTIONS]`:

| Option | What it runs |
|---|---|
| *(none)* | Default core run (the `FEATURES` set) |
| `--bundle tec` | TEC (India) certification dry-run evidence bundle |
| `--bundle trl8` | The 12 opt-in conformance/assurance features only |
| **`--bundle all`** | **The complete suite: 4G all 34 groups / 5G all 30 groups. Triggers the comprehensive report.** |
| `--feature <key>` | One feature group (e.g. `--feature volte`, `--feature load_5g`) |
| `--feature <key> --test <n>` | A single test case |
| `--list` | Print the full feature + test-case catalog |

Run `--list` for the authoritative per-TC catalog of the running version; it always matches the code.

## 5. Feature groups (both stacks)

| Category | 4G groups | 5G groups |
|---|---|---|
| Core E2E / health | EPC Health, HSS/AUC, PDN Session, Attach/Detach Churn, Regression, Bearer QoS | Regression, 5GC Health, NRF & SBI, AUSF/UDM, 5G Registration, PDU Session, PDU Profile |
| IMS voice/video | VoLTE, ViLTE, Conference, Advanced SIP, IMS IR.92/94 | VoNR, ViNR (video), Conference, Advanced SIP, IMS NG.114 |
| Messaging | SMS, MMS | SMS over 5GS, MMS over 5GS |
| Identity / interconnect | EIR, Inter-NIB | (AUSF/UDM auth), Network Slicing |
| Records / charging | CDR, Charging | CDR, Charging |
| **Capacity / performance** | **Load, Stress**, Perf KPI | **Load, Stress**, Perf KPI |
| Security & conformance | Security, NAS, SCAS/ITSAR, Diameter, PFCP, S1AP | Security, NAS, SCAS/ITSAR, SBI, PFCP/N4, NGAP/N2 |
| Assurance / ops | HA/Resilience, OAM/FCAPS, LI-readiness, TEC | HA/Resilience, OAM/FCAPS, LI-readiness |
| Disabled / optional | FXO/FXS, Mobile-to-IP | — |

## 6. Capacity / load / stress testing

Both stacks run real concurrency ramps as part of `--bundle all`:

- **4G** — `ue_sim` (S1AP/NAS simulator) ramps eNB S1-setup (→100), concurrent VoLTE/ViLTE attach+register (→128), ViLTE call-pairs, and burst attach (512/1024). The EPC core is CPU-bound around ~50 concurrent on this 8-vCPU host.
- **5G** — UERANSIM multi-UE (`nr-ue -i -n`) on **dedicated load gNBs** (`nr-gnb-load-0/1`, capped 256 UEs each; one UERANSIM gNB SIGSEGVs past ~256-512, so 512 is reached by sharding across 2 cells). Ramps: registration capacity → 128, headroom → 256, **sharded burst → 512**, PDU-session capacity, VoNR INVITE concurrency, plus a sustained-churn stress TC. The functional `nr-gnb`/`nr-ue` and subscriber `…0001` are never touched (load uses IMSI range `…0101+`).
  - **Key result:** the 5G *core* handles **512 concurrent registered UEs + 512 PDU sessions at ~0% CPU** — the ceiling is the simulator, not the 5GC (vs 4G's ~50 core ceiling).
- **Bundle order:** in `--bundle all`, **load + stress run LAST** on both stacks (their churn floods NF logs, which would otherwise scroll out the PFCP/PDU evidence later grep-based tests rely on). For 4G, `tec` runs right after them because its certification matrix reads the Load/Stress reports.
- **Line-rate user-plane throughput is REAL_HW-gated** (UERANSIM userspace GTP-U can't sustain bulk; the suite verifies reachability + jitter, not carrier line rate).

## 7. The comprehensive report

A full `--bundle all` run auto-generates a **per-stack, self-contained styled HTML report** (+ JSON sidecar) under `test/reports/comprehensive/`:

```
TEST_REPORT_4G_latest.html   TEST_REPORT_4G_latest.json
TEST_REPORT_5G_latest.html   TEST_REPORT_5G_latest.json
```
Open the `.html` in any browser (Ctrl/Cmd-P → Save as PDF for a shareable copy). It covers 10 sections: (1) hardware, (2) apps/modules, (3) limitations, (4) feature groups + aims, (5-7) per-TC aim/criterion/result, (8) failure & skip explanations + solutions, (9) totals, (10) a standards-aligned **Core/IMS KPI matrix** (accessibility, latency, throughput, media incl. E-model MOS, availability, **capacity incl. max concurrent registered UEs / PDU sessions / burst registration**, signalling). Retention is **latest-only** per stack; the generator (`test/lib/comprehensive_report.py`) is a read-only consumer — it never affects test outcomes. Individual `--feature`/`--test` runs do **not** trigger it.

## 8. Limitations (lab vs production)

- Simulated RAN/UE (UERANSIM / `ue_sim`): control-plane is real; bulk line-rate user-plane is REAL_HW-gated.
- Single 8-vCPU host: capacity numbers are lab-relative, not carrier dimensioning.
- No external OCS/CHF/CGF (charging) or ADMF/MDF/POI + X1/X2/X3 (LI) — these are audited as architecture-presence/honest findings, not exercised end-to-end.
- IPv4-only (no SMF IPv6 pool); EVS codec absent (AMR-WB interworking); MOS is an ITU-T G.107 E-model estimate, not POLQA/PESQ.
- Skips are explicit, by-design (REAL_HW gates + honest findings) and counted separately from failures.

## 9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| 5G NFs crash on first `up -d` with empty DB volumes | Mongo first-time init race — wait for Mongo, then run `sudo docker compose -f sa-vonr-deploy.yaml up -d` once more (see §3). |
| 5G UE won't register; gNB logs "AMF selection failed / context not found" | gNB's NG association went stale after an AMF restart — `docker restart nr-gnb` (then `nr-ue`). |
| Functional 5G UE flapping after heavy load / a core restart | `docker restart nr-gnb nr-ue`; confirm `nr-cli imsi-001010000000001 -e status` → `MM-REGISTERED` + PDU `PS-ACTIVE`. |
| `…#!/bin/bash: No such file or directory` when sourcing a feature | UTF-8 BOM on a feature file — cosmetic (functions still load); strip with `sed -i '1s/^\xEF\xBB\xBF//'`. |
| Windows edits not taking effect | CRLF — the runner strips `\r` from `*.sh` at startup; for other files run `sed -i 's/\r$//'`. |

---
*Authoritative per-test detail: `--list`. Per-run evidence: `test/reports/*.txt` + `test/reports/comprehensive/`.*
