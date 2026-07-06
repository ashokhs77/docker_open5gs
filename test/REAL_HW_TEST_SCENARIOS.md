# Real-Hardware Test Scenarios (TRL8)

This document lists the **real radio (gNB/eNB) + real UE** validations that the
simulator suite cannot fully prove on its own. The automated suite embeds each
of these as a **real-HW–gated test case** that stays `SKIP` until you run with
`REAL_HW=1`, so you can confirm them whenever a real setup is available.

> **Already validated on real HW:** basic 5G attach/registration and VoNR, and
> basic 4G attach and VoLTE, have been confirmed with real gNB/eNB + UEs.
> The scenarios below are the *next layer* — conformance- and security-grade
> checks that go beyond "a call works".

## How the real-HW gate works

- Set `REAL_HW=1` in the test container environment. The gated TCs then read the
  core-network logs (AMF for 5G, MME for 4G) and **PASS** when they find the
  expected procedure evidence, **FAIL** if `REAL_HW=1` but no evidence is present.
- With `REAL_HW` unset (default), those TCs `SKIP` with a pointer to this file,
  and the rest of the suite runs normally against the simulator.

Run examples (from the deployment folder):

```bash
# 5G — real gNB + UE attached to the 5GC, then:
docker compose -f test/docker-compose.test5g.yaml run --rm \
    -e REAL_HW=1 sipp-test-5g --feature nas_conformance_5g

# 4G — real eNB + UE attached to the EPC, then:
docker compose -f test/docker-compose.test.yaml run --rm \
    -e REAL_HW=1 sipp-test --feature nas_conformance
```

---

## Scenario RH-1 — 5G NR: NAS / 5G-AKA / security conformance (feature `nas_conformance_5g`, TC-12)

**Goal:** prove the *secured* registration procedure end-to-end on real radio,
beyond "the UE attaches".

**Pre-conditions:** real gNB with N2/NGAP to the AMF (`172.22.1.10:38412`), a real
USIM provisioned in MongoDB/UDM (matching MCC/MNC and Ki/OPc), `REAL_HW=1`.

**Steps & what to confirm:**
1. gNB **NG Setup** completes (AMF accepts the NG-RAN node).
2. UE **Initial Registration** runs through **5G-AKA** with the real USIM
   (RAND/AUTN challenge, RES* verification) — not a lab null-auth.
3. **NAS Security Mode** activates real ciphering + integrity (NEA1/NEA2 + NIA1/NIA2),
   confirming TC-2/TC-3 policy is actually exercised on the air interface.
4. **Registration Accept** carries a **5G-GUTI**.
5. **PDU session** establishes with a **QoS flow** (default 5QI), data plane up.

**Evidence to capture:** `docker logs amf`, `docker logs smf`, `docker logs ausf`
around the registration window; optionally a gNB-side trace. Attach these to the
TRL8 evidence pack.

**Beyond the automated TC (manual real-HW checks worth doing):**
- VoNR call on the real UE with IMS-AKA + IPSec SA (SA1–SA4) to P-CSCF.
- EPS-fallback / RAT-fallback for voice if the deployment uses it.
- Mobility: cell reselection / handover keeping the PDU session.

---

## Scenario RH-2 — 4G LTE: EMM / EPS-AKA / security conformance (feature `nas_conformance`, TC-10)

**Goal:** prove the secured EPS attach on real radio, complementing the regression
feature (which already covers TAU, GUTI re-attach, paging and SQN resync in sim).

**Pre-conditions:** real eNB with S1 to the MME, real USIM in the HSS, `REAL_HW=1`.

**Steps & what to confirm:**
1. eNB **S1 Setup** completes.
2. UE **Attach** runs **EPS-AKA** with the real USIM (auth vectors over S6a from HSS).
3. **NAS Security Mode** activates real EEA/EIA ciphering+integrity.
4. **Attach Accept** carries a **GUTI**; **default EPS bearer** (QCI-9) activates.
5. (Manual) VoLTE call: dedicated **QCI-1** bearer via Rx, then teardown on BYE.

**Evidence to capture:** `docker logs mme`, `docker logs pyhss`, `docker logs smf`
around the attach window.

---

## Forward-looking scenarios (added as TRL8 features land)

These will each gain a `REAL_HW=1` gated TC as the corresponding feature is built.
Tracked in memory `project-trl8-program`.

| Future feature | Real-HW scenario to confirm |
|---|---|
| SBI / Diameter conformance | (control-plane only — fully sim-testable; no real-HW gate) |
| ~~SCAS / ITSAR hardening~~ **(landed as features `scas_itsar_5g` / `scas_itsar` — posture audit, fully sim-testable)** | Manual real-UE check remains: confirm no plaintext IMSI/SUPI on the air interface with a radio trace (SUCI in use on 5G) |
| NGAP/S1AP conformance | Real handover (Xn/N2, X2/S1), paging on real MT call |
| IMS NG.114 / IR.92-94 | Real-UE VoNR/VoLTE with EVS/AMR-WB codec, ViNR/ViLTE video, emergency 112 |
| Performance KPI | Real-RAN capacity: registrations/s, CAPS, throughput at the cell |
| Interface evidence (`interface_evidence` / `interface_evidence_5g`) | Attach S1/N2, NAS, PFCP/N4, GTP-U/N3, and SIP pcaps from the real eNB/gNB/UE window with `REAL_HW=1` and `INTERFACE_EVIDENCE_REAL_HW_PCAP=<mounted pcap>`. |
| HA / resilience | NF failover with live UEs registered (no call drop) |

_Last updated: 2026-06-10 — seeded with RH-1 (5G) and RH-2 (4G) NAS conformance._
