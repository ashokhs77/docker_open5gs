#!/bin/bash
# 4G EPC + IMS Comprehensive Integration Test Suite
# Usage:
#   ./run_tests.sh                          # Run default core tests
#   ./run_tests.sh --feature volte          # Run VoLTE tests only
#   ./run_tests.sh --feature cdr --test 3   # Run CDR test case 3 only
#   ./run_tests.sh --bundle tec             # Run TEC dry-run evidence bundle
#   ./run_tests.sh --list                   # List all features and test cases

set +e

normalize_shell_scripts() {
    find /opt/test -type f -name "*.sh" -exec sed -i 's/\r$//' {} + 2>/dev/null || true
}

normalize_shell_scripts

source /opt/test/lib/common.sh
source /opt/test/lib/sipp_helpers.sh

# Source all feature scripts
source /opt/test/features/00_epc_health.sh
source /opt/test/features/00_hss_auc_auth.sh
source /opt/test/features/00_pdn_session.sh
source /opt/test/features/00_pyhss_api_negative.sh
source /opt/test/features/00_attach_detach_churn.sh
source /opt/test/features/01_volte.sh
source /opt/test/features/02_vilte.sh
source /opt/test/features/03_eir.sh
source /opt/test/features/04_sms.sh
source /opt/test/features/05_inter_nib.sh
source /opt/test/features/06_conference.sh
source /opt/test/features/07_fxo_fxs.sh
source /opt/test/features/08_cdr.sh
source /opt/test/features/09_load_test.sh
source /opt/test/features/10_regression.sh
source /opt/test/features/11_mms.sh
source /opt/test/features/12_stress.sh
source /opt/test/features/13_bearer_qos.sh
source /opt/test/features/14_mobile_ip.sh
source /opt/test/features/15_tec.sh
source /opt/test/features/16_advanced_sip.sh
source /opt/test/features/17_security.sh

# TRL8 conformance/assurance add-on features (opt-in; see --bundle trl8)
source /opt/test/features/18_nas_conformance.sh
source /opt/test/features/19_scas_itsar.sh
source /opt/test/features/20_diameter_conformance.sh
source /opt/test/features/21_pfcp_n4.sh
source /opt/test/features/22_s1ap.sh
source /opt/test/features/23_ims_ng114.sh
source /opt/test/features/24_perf_kpi.sh
source /opt/test/features/25_ha_resilience.sh
source /opt/test/features/26_oam_fcaps.sh
source /opt/test/features/27_charging.sh
source /opt/test/features/28_li_presence.sh
source /opt/test/features/29_interface_evidence.sh

# Parse arguments
FEATURE=""
TEST_NUM=0
BUNDLE=""

# Map feature names to functions
FEATURES=(
    "epc_health:run_epc_health_tests:EPC Health"
    "hss_auc:run_hss_auc_tests:HSS AUC Auth"
    "pdn_session:run_pdn_session_tests:PDN Session"
    "pyhss_api:run_pyhss_api_tests:PyHSS API Negative"
    "attach_churn:run_attach_churn_tests:Attach Detach Churn"
    "regression:run_regression_tests:Regression"
    "volte:run_volte_tests:VoLTE"
    "vilte:run_vilte_tests:ViLTE"
    "eir:run_eir_tests:EIR"
    "sms:run_sms_tests:SMS"
    "inter_nib:run_inter_nib_tests:Inter-NIB"
    "conference:run_conference_tests:Conference"
    "fxo_fxs:run_fxo_fxs_tests:FXO/FXS"
    "mobile_ip:run_mobile_ip_tests:Mobile-to-IP"
    "cdr:run_cdr_tests:CDR"
    "load:run_load_tests:Load Test"
    "mms:run_mms_tests:MMS"
    "stress:run_stress_tests:Stress Test"
    "bearer_qos:run_bearer_qos_tests:Bearer QoS"
    "tec:run_tec_tests:TEC Readiness"
    "advanced_sip:run_advanced_sip_tests:Advanced SIP"
    "security:run_security_tests:Security"
)

TEC_BUNDLE_FEATURES=(
    "epc_health"
    "hss_auc"
    "pdn_session"
    "pyhss_api"
    "attach_churn"
    "regression"
    "volte"
    "vilte"
    "eir"
    "sms"
    "inter_nib"
    "conference"
    "fxo_fxs"
    "cdr"
    "load"
    "stress"
    "bearer_qos"
    "mobile_ip"
    "mms"
    "tec"
    "advanced_sip"
    "security"
)

# ============================================================
# TRL8 conformance & assurance add-on (opt-in). Kept OUT of the default
# no-arg run and the 'tec' bundle, keeping deployment/dev smoke runs
# separate from release-assurance coverage. Exposed via --feature <key>, --bundle trl8,
# and --bundle all.
# ============================================================
TRL8_FEATURE_MAP=(
    "nas_conformance:run_nas_conformance_tests:NAS Conformance"
    "scas_itsar:run_scas_itsar_tests:SCAS/ITSAR Security"
    "diameter_conformance:run_diameter_conformance_tests:Diameter Conformance"
    "pfcp_n4:run_pfcp_n4_tests:PFCP Conformance"
    "s1ap:run_s1ap_tests:S1AP Conformance"
    "ims_ng114:run_ims_ng114_tests:IMS Profile IR.92/94"
    "perf_kpi:run_perf_kpi_tests:Performance KPI"
    "ha_resilience:run_ha_resilience_tests:HA / Resilience"
    "oam_fcaps:run_oam_fcaps_tests:OAM / FCAPS"
    "charging:run_charging_tests:Charging"
    "li_presence:run_li_presence_tests:LI Readiness"
    "interface_evidence:run_interface_evidence_tests:Interface Evidence"
)

BUNDLE_TRL8_FEATURES=(
    "nas_conformance"
    "scas_itsar"
    "diameter_conformance"
    "pfcp_n4"
    "s1ap"
    "ims_ng114"
    "perf_kpi"
    "ha_resilience"
    "oam_fcaps"
    "charging"
    "li_presence"
    "interface_evidence"
)

# Everything: all core features (in catalog order) + TRL8 add-on
BUNDLE_ALL_FEATURES=(
    "epc_health"
    "hss_auc"
    "pdn_session"
    "pyhss_api"
    "attach_churn"
    "regression"
    "volte"
    "vilte"
    "eir"
    "sms"
    "inter_nib"
    "conference"
    "fxo_fxs"
    "mobile_ip"
    "cdr"
    "load"
    "mms"
    "stress"
    "bearer_qos"
    "tec"
    "advanced_sip"
    "security"
    "nas_conformance"
    "scas_itsar"
    "diameter_conformance"
    "pfcp_n4"
    "s1ap"
    "ims_ng114"
    "perf_kpi"
    "ha_resilience"
    "oam_fcaps"
    "charging"
    "li_presence"
    "interface_evidence"
)

show_list() {
    cat <<'EOF'
============================================================
  4G EPC + IMS Integration Test Suite - Test Catalog
============================================================

Feature: EPC Health (--feature epc_health)
  TC-1:  MME running + S1AP SCTP port 36412 listening
  TC-2:  SGW-C running + GTPv2-C port 2123 listening
  TC-3:  SGW-U running + GTP-U port 2152 listening
  TC-4:  SMF/PGW-C running + PFCP port 8805 listening
  TC-5:  UPF/PGW-U running + GTP-U port 2152 listening
  TC-6:  PyHSS running + REST API reachable
  TC-7:  MySQL running + SQL port reachable
  TC-8:  DNS running + P-CSCF A record resolves
  TC-9:  P-CSCF running + SIP port reachable
  TC-10: I-CSCF running + SIP port reachable
  TC-11: S-CSCF running + SIP port reachable
  TC-12: FreeSWITCH running
  TC-13: RTPEngine running/reachable
  TC-14: SMSC running + SIP port bound
  TC-15: MMSC running
  TC-16: I-CSCF Cx Diameter peer open
  TC-17: S-CSCF Cx Diameter peer open
  TC-18: P-CSCF Rx Diameter peer open
  TC-19: SMF/UPF PFCP health evidence present
  TC-20: No EPC/IMS container restart loops

Feature: HSS/AUC Auth (--feature hss_auc)
  TC-1:  PyHSS REST + S6a Diameter ports reachable
  TC-2:  Dedicated auth subscribers provisioned via PyHSS API
  TC-3:  AUC/subscriber MySQL mapping and credentials valid
  TC-4:  Milenage vector derivation from provisioned AUC data
  TC-5:  Positive EPC attach authenticates and negotiates NAS security
  TC-6:  AUC SQN advances after a successful attach
  TC-7:  Valid IMSI with wrong Ki is rejected
  TC-8:  Unknown IMSI is rejected
  TC-9:  SQN re-synchronisation via AUTS succeeds
  TC-10: IMS AKA registration succeeds for the auth subscriber

Feature: PDN Session (--feature pdn_session)
  TC-1:  EPC user-plane NFs and primary ports are ready
  TC-2:  PyHSS APN profiles for internet and ims are present
  TC-3:  internet APN IPv4 default bearer assigns an IPv4 address
  TC-4:  ims APN IPv4 default bearer assigns an IPv4 address
  TC-5:  IPv4v6 PDN request is accepted or cleanly downgraded/skipped
  TC-6:  IPv6-only PDN request gets a prefix or records the lab gap
  TC-7:  Unknown APN is rejected
  TC-8:  PDN attach produces PFCP/GTP control-plane evidence
  TC-9:  UE detach releases the PDN context cleanly

Feature: PyHSS API Negative (--feature pyhss_api)
  TC-1:  PyHSS REST API reachable before negative-input battery
  TC-2:  Unknown subscriber lookup returns clean not-found/no-data
  TC-3:  Unknown AUC lookup returns clean not-found/no-data
  TC-4:  Malformed IMSI path is rejected without 5xx
  TC-5:  Malformed JSON AUC PUT is rejected without 5xx
  TC-6:  Invalid AUC field lengths are rejected without 5xx
  TC-7:  Invalid subscriber APN/AUC references are rejected without 5xx
  TC-8:  Invalid IMS subscriber identity/route is rejected without 5xx
  TC-9:  Unsupported API method/path is rejected without 5xx
  TC-10: PyHSS remains alive after negative-input battery and leaves no residue

Feature: Attach/Detach Churn (--feature attach_churn)
  TC-1:  UE simulator and EPC churn prerequisites are ready
  TC-2:  Single attach/detach lifecycle succeeds
  TC-3:  Same subscriber survives repeated attach/detach cycles
  TC-4:  Alternating subscribers survive repeated attach/detach cycles
  TC-5:  Fast back-to-back attach/detach cycles remain stable
  TC-6:  Mini concurrent attach/detach churn burst remains stable
  TC-7:  Core containers do not restart during churn
  TC-8:  Detach/context-release evidence appears or is explicitly recorded
  TC-9:  Clean attach/detach succeeds after churn

Feature: Regression (--feature regression)
  Cat 1: Container Health
  TC-1:  All EPC containers running
  TC-2:  All IMS containers running
  TC-3:  All infrastructure containers running
  TC-4:  No container restart loops
  Cat 2: Diameter Interface Health
  TC-5:  S6a Diameter (MME to PyHSS)
  TC-6:  Cx Diameter (I-CSCF to PyHSS)
  TC-7:  Cx Diameter (S-CSCF to PyHSS)
  TC-8:  Rx Diameter (P-CSCF to PyHSS/PCRF)
  TC-9:  Kamailio IMS modules loaded
  Cat 3: EPC Data Plane
  TC-10: PFCP association (SMF to UPF)
  TC-11: GTPv2-C (SGWC)
  TC-12: GTPv1-U (SGWU data plane)
  Cat 4: IMS Signaling Chain
  TC-13: FreeSWITCH ESL health
  TC-14: FreeSWITCH Sofia profiles
  TC-15: RTPEngine health
  TC-16: P-CSCF routing config
  TC-17: S-CSCF AS routing
  Cat 5: Full E2E Call
  TC-18: Single UE attach + IMS register
  TC-19: Full VoLTE MO call (INVITE + BYE)
  TC-20: VoLTE call teardown (CDR)
  TC-21: SIP re-REGISTER
  Cat 6: Negative Tests
  TC-22: Invalid IMSI attach (expect reject)
  TC-23: Wrong Ki auth (expect failure)
  TC-24: Unregistered UE INVITE (expect reject)
  TC-25: PyHSS API non-existent subscriber
  TC-26: Call non-existent MSISDN
  TC-27: MySQL health
  Cat 7: Subscriber Lifecycle
  TC-28: Provision lifecycle subscriber
  TC-29: Verify via API
  TC-30: Verify in MySQL
  TC-31: E2E with lifecycle subscriber
  TC-32: Delete lifecycle subscriber
  TC-33: Verify purged
  TC-34: VoLTE hold/resume with real caller and callee
  Cat 8: EPC Mobility & Security
  TC-37: TAU (Tracking Area Update)
  TC-38: SQN re-synchronisation (AUTS)
  TC-39: Subsequent attach with GUTI
  TC-40: MT paging (UE goes idle, MME pages on MT call)
  TC-41: P-CSCF recovery after container restart
  TC-42: SIP re-registration timer refresh
  TC-43: Codec negotiation rejection (488)
  Cat 9: NAS Ciphering & PDN Type
  TC-44: NAS security algorithm enforcement
  TC-45: Integrity-protected attach procedure
  TC-46: Ciphered control-plane evidence
  TC-47: IPv4 PDN attach and address assignment
  TC-48: IPv6 PDN attach and prefix assignment
  TC-49: IPv6 MT paging after attach

Feature: VoLTE (--feature volte)
  TC-1: DNS P-CSCF A record
  TC-2: DNS I-CSCF SRV record
  TC-3: DNS S-CSCF SRV record
  TC-4: P-CSCF SIP reachability
  TC-5: S-CSCF SIP reachability
  TC-6: I-CSCF SIP reachability
  TC-7: RTPEngine health check
  TC-8: Intra-NIB VoLTE INVITE (9876540001 -> 9876541000, same IMS domain)
  TC-9: Inter-NIB VoLTE INVITE (callee at external.example, non-5xx required)
  TC-10: Active PLMN identification and DNS consistency
  TC-11: Optimus/MTK sec-agree remains on Gm IPsec (not 420)
  TC-12: Samsung sec-agree remains on Gm IPsec (not 420)
  TC-13: VoLTE INVITE as Optimus/MTK UA
  TC-14: VoLTE INVITE as Samsung UA
  TC-15: Inter-NIB terminating Request-URI identity preservation deployed

Feature: ViLTE (--feature vilte)
  TC-1:  P-CSCF sdpops module loaded
  TC-2:  P-CSCF rtpengine module loaded
  TC-3:  P-CSCF video flow authorization enabled
  TC-4:  P-CSCF video bandwidth config
  TC-5:  RTPEngine reachability from P-CSCF
  TC-6:  RTPEngine process health
  TC-7:  S-CSCF video CDR detection configured
  TC-8:  P-CSCF codec/transcoding flags configured
  TC-9:  Intra-NIB ViLTE INVITE (audio+video SDP, same IMS domain)
  TC-10: Inter-NIB ViLTE INVITE (audio+video SDP, callee at external.example)
  TC-11: Mid-call media type switch (audio<->video re-INVITE)

Feature: EIR (--feature eir)
  TC-1: PyHSS API reachable
  TC-2: EIR config contains imsi_imei_logging
  TC-3: Subscriber AUC provisioning
  TC-4: Subscriber query
  TC-5: IMS subscriber provisioning
  TC-6: AUC entry verification

Feature: SMS (--feature sms)
  TC-1: SMSC DNS resolution
  TC-2: SMSC SRV record
  TC-3: SMSC SIP port reachability
  TC-4: SIP MESSAGE direct to SMSC (basic smoke)
  TC-5: MySQL SMSC database check
  TC-6: Intra-NIB SIP MESSAGE via IMS chain (P-CSCF -> S-CSCF -> SMSC)
  TC-7: Intra-NIB SMS delivery confirmation (MySQL messages table)
  TC-8: Inter-NIB SMS routing (no 5xx for external URI)
  TC-9: SMS message body integrity (known text in MySQL)
  TC-10: Store-and-forward — SMS to offline recipient stored + queued (pending_ue) + retained (not dropped)
  TC-11: USER_ONLINE trigger (S-CSCF re-register signal) flushes pending_ue
  TC-12: 48-hour expiry — over-age stored SMS discarded
  TC-13: Invalid-recipient guard — SMS to a non-MSISDN (e.g. 8-digit) is rejected before storage

Feature: Inter-NIB (--feature inter_nib)
  TC-1: DNS SRV for I-CSCF
  TC-2: DNS SRV for S-CSCF
  TC-3: P-CSCF port 5060 open
  TC-4: I-CSCF port 4060 open
  TC-5: S-CSCF port 6060 open
  TC-6: I-CSCF inter-domain federation routing config
  TC-7: DNS resolver reachability for inter-NIB SRV queries
  TC-8: Inter-NIB SIP INVITE routing via I-CSCF (non-5xx required)

Feature: Conference (--feature conference)
  TC-1:  DNS conf-factory resolution
  TC-2:  Direct FreeSWITCH VoLTE conference (1010)
  TC-3:  P-CSCF VoLTE conf-factory routing
  TC-4:  Direct FreeSWITCH ViLTE conference (1010 with video SDP)
  TC-5:  P-CSCF ViLTE conf-factory routing
  TC-6:  Sequential conference rooms
  TC-7:  Multi-member conference join (4 members)
  TC-8:  Hold SDP via conf-factory
  TC-9:  Conference cleanup/room reuse (1013)
  TC-10: Concurrent conferences (1014 + 1015)
  TC-11: Rx AAR behavior for conference INVITE
  TC-12: Rx Diameter peer connectivity
  TC-13: Inter-NIB conference INVITE (sip:1010@external.example, non-5xx required)
  TC-14: 24-member SINGLE audio conference — join + sustained hold past rtp-timeout (stability primary; join count is in-suite ceiling, full N via real-UE/multi-host)
  TC-15: 8-member  SINGLE video conference — join + sustained hold (stability primary; real video media needs real UEs)

Feature: FXO/FXS (--feature fxo_fxs)
  Temporarily disabled pending confirmed production call path

Feature: Mobile-to-IP (--feature mobile_ip)
  TC-1: Same-IMS softphone target configuration
  TC-2: P-CSCF MT route configuration
  TC-3: S-CSCF local terminating lookup configuration
  TC-4: Mobile UE attach + IMS register for softphone scenario
  TC-5: Mobile-originated call to same-IMS softphone target
  TC-6: Current-run MT and media evidence for softphone path

Feature: CDR (--feature cdr)
  TC-1: CDR log file exists
  TC-2: CDR htable configured
  TC-3: CDR after call
  TC-4: CDR fields validation
  TC-5: CDR audio type
  TC-6: CDR logrotate config exists
  TC-7: CDR field completeness (all fields non-empty and type-valid)

Feature: Load Test (--feature load)
  TC-1: eNB S1Setup connection capacity (ramp 1->100)
  TC-2: VoLTE attach+register capacity (single shared eNB)
  TC-3: ViLTE attach+register capacity (single shared eNB)
  TC-4: PyHSS API throughput (subscriber queries/sec)
  TC-5: DNS query throughput (queries/sec)
  TC-6: Sustained data plane throughput (iperf3 multi-stream)
  TC-7: Voice-grade jitter measurement (iperf3 UDP VoLTE bitrate)
  TC-8: Concurrent bearer traffic (internet + IMS simultaneous)
  TC-9: Maximum registered subscribers per eNB
  TC-10: VoLTE/ViLTE simultaneous call-pair capacity
  TC-11: Attach burst simulation (single-eNB + multi-eNB)

Feature: MMS (--feature mms)
  TC-1:  MMSC container running
  TC-2:  Kannel bearerbox port 13000
  TC-3:  Kannel smsbox port 13001
  TC-4:  Kannel sendsms HTTP 13013
  TC-5:  Mbuni WAP gateway port 8090
  TC-6:  Mbuni SendMMS API port 8181
  TC-7:  Kannel admin status
  TC-8:  SMPP connection to OsmoMSC
  TC-9:  MMS storage volume mounted
  TC-10: MMS send via SendMMS API (external recipient smoke)
  TC-11: Kannel log health
  TC-12: Mbuni log health
  TC-13: MMS notification SMS path
  TC-14: MMSC process health
  TC-15: MM7 incoming port 8190
  TC-16: Intra-NIB MMS send A->B (same MMSC domain, storage verified)
  TC-17: Intra-NIB MMS delivery queue (recipient entry in MMSC storage)
  TC-18: Inter-NIB MMS MM7 outbound (external MSISDN via MM7 port 8190)

Feature: Stress Test (--feature stress)
  TC-1: P-CSCF resource configuration audit (SHM, IPSec, CDP)
  TC-2: Concurrent VoLTE calls under multi-UE load
  TC-3: Long-duration VoLTE call stability (session-timer resilience)
  TC-4: Rx Diameter health under load (CDP threshold monitoring)
  TC-5: P-CSCF shared memory utilization under load
  TC-6: IPSec port exhaustion detection
  TC-7: In-dialog AAR failure resilience (call survives QoS refresh failure)
  TC-8: Multi-call concurrent stability

Feature: Bearer QoS (--feature bearer_qos)
  TC-1:  QCI-9 default bearer at EPC attach (internet APN)
  TC-2:  QCI-5 IMS signaling path at IMS registration
  TC-3:  Rx AAR trigger via +g.3gpp.icsi-ref Contact header
  TC-4:  QCI-1 VoLTE dedicated bearer during voice call
  TC-5:  QCI-2 ViLTE dedicated bearer during video call
  TC-6:  Dedicated bearer teardown on BYE (Rx STR)
  TC-7:  P-CSCF Rx Diameter peer health for bearer path
  TC-8:  Bearer QCI values in P-CSCF Rx AAR logs
  TC-9:  iperf3 data plane test on default bearer (QCI-9)
  TC-10: iperf3 data plane test on IMS bearer/signaling path (QCI-5)

Feature: TEC Readiness (--feature tec)
  TC-1:  TEC evidence harness and run artifacts
  TC-2:  EPC attach + IMS registration baseline
  TC-3:  IMS SIP/DNS readiness
  TC-4:  Bearer QoS and dedicated bearer lifecycle
  TC-5:  Attach/load/capacity evidence
  TC-6:  Long-call, session timer, and 477 resilience
  TC-7:  Conference and call merge infrastructure
  TC-8:  SMS and MMS evidence
  TC-9:  Mobile-to-IP and softphone path
  TC-10: Real-UE RF/media acceptance lane
  TC-11: VoWiFi/ePDG acceptance lane
  TC-12: Analog FXO/FXS and ringback path
  TC-13: LI, billing, HA, 3GPP study, NB-IoT, NTN

Feature: Advanced SIP (--feature advanced_sip)
  TC-1: RTP echo validation (SIPp UAC/UAS -rtp_echo)
  TC-2: DTMF SIP INFO (application/dtmf-relay)
  TC-3: REFER call transfer (202 Accepted + NOTIFY)
  TC-4: Emergency INVITE sip:112 (no 5xx)
  TC-5: IPv6 REGISTER (no 5xx from P-CSCF)

Feature: Security (--feature security)
  TC-1:  Unauthenticated REGISTER → 401 challenge (auth enforcement)
  TC-2:  INVITE to unknown subscriber → 4xx (no routing leak or crash)
  TC-3:  SIP OPTIONS probe → non-5xx response (enumeration resilience)
  TC-4:  Max-Forwards: 0 INVITE → 483 Too Many Hops (RFC 3261 loop prevention)
  TC-5:  Oversized Via header → 4xx, no crash (buffer safety probe)
  TC-6:  Orphan BYE (no active dialog) → 481 (state machine robustness)
  TC-7:  Orphan CANCEL (no active transaction) → 481 (state machine robustness)
  TC-8:  Invalid SDP INVITE (no m= lines) → 4xx/488 (SDP parse safety)
  TC-9:  PyHSS API probe — unknown IMSI returns 404, not 5xx (API crash safety)
  TC-10: P-CSCF DoS resilience — port alive after all security probes

------------------------------------------------------------
  TRL8 Conformance & Assurance add-on
  (opt-in: --bundle trl8 | --bundle all | --feature <key>;
   NOT part of the default run or the 'tec' bundle)
------------------------------------------------------------

Feature: NAS Conformance (--feature nas_conformance)
  TC-1:  MME S1AP ready to transport EPS NAS
  TC-2:  NAS integrity algorithm policy (EIA1/EIA2)        [TS 33.401]
  TC-3:  NAS ciphering algorithm capability (EEA1/EEA2)    [TS 33.401]
  TC-4:  EPS-AKA authentication evidence over S6a          [TS 33.401]
  TC-5:  NAS Security Mode Command/Complete evidence       [TS 24.301]
  TC-6:  Attach Accept + GUTI assignment evidence          [TS 24.301]
  TC-7:  ESM default EPS bearer activation evidence        [TS 24.301]
  TC-8:  Attach Reject EMM-cause conformance               [TS 24.301]
  TC-9:  Periodic TAU timer T3412 configuration
  TC-10: [REAL-HW] Real eNB S1 Setup + real UE EPS-AKA attach (REAL_HW=1)

Feature: SCAS/ITSAR Security (--feature scas_itsar)
  TC-1:  No insecure remote-access services on EPC NFs     [TS 33.117]
  TC-2:  No insecure services on IMS NFs + datastores      [TS 33.117]
  TC-3:  MySQL credential posture (no passwordless root)   [ITSAR]
  TC-4:  MongoDB authentication posture (if deployed)      [ITSAR]
  TC-5:  Diameter transport security (TLS/No_TLS posture)  [TS 33.210]
  TC-6:  Diameter peer authentication / allow-listing      [TS 33.210]
  TC-7:  Subscriber identity privacy (no clear IMSI in logs)
  TC-8:  NFs run as non-root (least privilege)             [TS 33.117]
  TC-9:  S1/data-plane transport protection (IPsec)        [TS 33.401]
  TC-10: Management API authentication posture (PyHSS)     [ITSAR]
  TC-11: Listening-port inventory evidence (attack surface)
  TC-12: ITSAR hardening posture summary (evidence emitter)

Feature: Diameter Conformance (--feature diameter_conformance)
  TC-1:  Diameter base transport listening (3868)          [RFC 6733]
  TC-2:  CER/CEA capabilities-exchange evidence            [RFC 6733]
  TC-3:  Device-Watchdog DWR/DWA evidence                  [RFC 6733]
  TC-4:  S6a application (16777251) advertised             [TS 29.272]
  TC-5:  S6a AIR/AIA authentication-information evidence   [TS 29.272]
  TC-6:  S6a ULR/ULA update-location evidence              [TS 29.272]
  TC-7:  Cx UAR/UAA user-authorization evidence            [TS 29.228]
  TC-8:  Cx MAR/SAR registration evidence                  [TS 29.228]
  TC-9:  Rx application (16777236) advertised              [TS 29.214]
  TC-10: Result-Code discipline (2001 / 5001-5030)         [RFC 6733]
  TC-11: Origin-Host/Origin-Realm identity conformance     [RFC 6733]
  TC-12: Diameter peer stability across CSCFs (cdp Open)   [RFC 6733]

Feature: PFCP Conformance (--feature pfcp_n4)
  TC-1:  SGW-U PFCP server bound (8805/UDP)                [TS 29.244]
  TC-2:  UPF PFCP server bound (8805/UDP)                  [TS 29.244]
  TC-3:  Sxa SGW-C<->SGW-U PFCP association                 [TS 29.244]
  TC-4:  Sxb SMF<->UPF PFCP association                     [TS 29.244]
  TC-5:  PFCP node configuration audit (server/client)     [TS 29.244]
  TC-6:  PFCP request/response message exchange            [TS 29.244]
  TC-7:  SGW-U GTP-U S1-U data plane bound (2152/UDP)      [TS 29.281]
  TC-8:  PFCP association liveness / keepalive              [TS 29.244]
  TC-9:  PFCP Session Establishment evidence               [TS 29.244]
  TC-10: PFCP rules PDR/FAR/QER installation evidence      [TS 29.244]
  TC-11: PFCP Usage Reporting (URR) for charging           [TS 29.244]
  TC-12: PFCP association restoration / recovery           [TS 23.527]

Feature: S1AP Conformance (--feature s1ap)
  TC-1:  MME S1AP SCTP transport bound (36412)             [TS 36.412]
  TC-2:  MME S1AP config audit (PLMN/TAC/GUMMEI/TAI)       [TS 36.413]
  TC-3:  S1 Setup / eNB S1 association                      [TS 36.413]
  TC-4:  Initial UE Message (NAS over S1)                   [TS 36.413]
  TC-5:  S1AP UE identity management (ENB/MME_UE_S1AP_ID)   [TS 36.413]
  TC-6:  UE Context Release procedure                       [TS 36.413]
  TC-7:  SCTP association multi-streaming (S1AP)            [TS 36.412]
  TC-8:  Initial Context Setup / E-RAB management           [TS 36.413]
  TC-9:  Paging procedure                                   [TS 36.413]
  TC-10: Reset procedure handling                           [TS 36.413]
  TC-11: Error Indication / Overload handling               [TS 36.413]
  TC-12: [REAL-HW] Real eNB S1 Setup + S1AP UE context (REAL_HW=1)

Feature: IMS Profile (IR.92/IR.94) (--feature ims_ng114)
  TC-1:  P-CSCF IMS registrar capability                   [TS 24.229]
  TC-2:  IMS access-security: IPSec module loaded          [TS 33.203]
  TC-3:  IPSec SA parameters (SPI range + ports)           [TS 33.203]
  TC-4:  IPSec integrity/encryption posture (ealg)         [TS 33.203]
  TC-5:  IMS authentication enforced (REGISTER->401)       [IR.92]
  TC-6:  Mandatory voice codec AMR                         [IR.92]
  TC-7:  Mandatory wideband codec AMR-WB                   [IR.92]
  TC-8:  EVS codec (NG.114 5G voice)                       [NG.114]
  TC-9:  Video codec H.264 (ViLTE/ViNR)                    [IR.94]
  TC-10: Media plane: SDP manipulation + RTP anchoring     [IR.92]
  TC-11: IMS registration evidence                         [TS 24.229]
  TC-12: SIP reliable-provisional/precondition readiness   [RFC 3312]

Feature: Performance KPI (--feature perf_kpi)
  TC-1:  PyHSS REST API latency p50/p95                    [TS 28.554]
  TC-2:  DNS resolution latency p50/p95                    [TS 28.554]
  TC-3:  PyHSS API success-rate KPI                        [TS 28.554]
  TC-4:  EPS attach procedure latency (MME log)            [TS 28.554]
  TC-5:  Default bearer / session setup latency            [TS 28.554]
  TC-6:  User-plane round-trip latency                     [TS 28.554]
  TC-7:  User-plane throughput                             [TS 28.554]
  TC-8:  Registered-UE capacity snapshot (MME)             [TS 28.554]
  TC-9:  NF CPU/memory utilization (headroom)              [TS 28.554]
  TC-10: Control-plane (API) latency stability under load  [TS 28.554]
  TC-11: PyHSS API request throughput (req/s)              [TS 28.554]
  TC-12: KPI evidence matrix (TS 28.554)

Feature: HA / Resilience (--feature ha_resilience)   [** restarts NFs — run isolated/last **]
  TC-1:  SGW-U PFCP restoration (recovery-timestamp+re-assoc)  [TS 23.527]
  TC-2:  PFCP recovery-timestamp peer-restart detection        [TS 23.527]
  TC-3:  SMF<->UPF (Sxb) PFCP restoration on UPF restart        [TS 23.527]
  TC-4:  Diameter peer recovery on PyHSS restart               [RFC 6733]
  TC-5:  MME control-plane restart recovery (S1AP re-bind)     [TS 23.007]
  TC-6:  NF crash-loop stability (RestartCount)                [robustness]
  TC-7:  NF clean re-initialization after restart              [TS 23.527]
  TC-8:  Data-store HA posture (replica / failover)            [HA]
  TC-9:  PFCP heartbeat liveness / peer supervision            [TS 29.244]
  TC-10: Recovery time measurement (restart -> service back)   [KPI]
  TC-11: Restoration coverage across PFCP nodes                [TS 23.527]
  TC-12: HA / restoration evidence summary

Feature: OAM / FCAPS (--feature oam_fcaps)
  TC-1:  PM: MME metrics endpoint reachable (:9091)        [TS 28.552]
  TC-2:  PM: EPC PM counters exported                      [TS 28.552]
  TC-3:  PM: Prometheus/OpenMetrics format (HELP/TYPE)     [TS 28.552]
  TC-4:  PM: multiple NFs export metrics (MME/SMF/UPF)     [TS 28.552]
  TC-5:  PM: Prometheus collector reachable + query API    [OAM]
  TC-6:  FM: per-NF target health via 'up' metric          [TS 28.545]
  TC-7:  FM: NF fault/error counters present               [TS 28.545]
  TC-8:  FM: NF crash/restart supervision (RestartCount)   [TS 28.545]
  TC-9:  CM: NF metrics configuration consistency          [EPC NRM]
  TC-10: Visualization: Grafana dashboards reachable       [OAM]
  TC-11: Logging: NF structured logging accessible         [OAM]
  TC-12: OAM / FCAPS coverage summary

Feature: Charging (--feature charging)
  TC-1:  Gx policy+charging-control transport (SMF<->PyHSS) [TS 29.212]
  TC-2:  Policy+charging node present (Diameter hub)       [TS 23.203]
  TC-3:  Gx Credit-Control charging trigger (CCR)          [TS 32.251]
  TC-4:  IMS offline CDR mechanism                         [TS 32.260]
  TC-5:  PFCP usage measurement (URR)                      [TS 32.251]
  TC-6:  Online charging system (Gy/OCS)                   [TS 32.299]
  TC-7:  Offline charging gateway (Gz/CGF)                 [TS 32.295]
  TC-8:  QCI / charging-characteristics based rating       [TS 32.251]
  TC-9:  CDR field/format conformance                      [TS 32.298]
  TC-10: CDR file transfer to CGF (Bd/Ga)                  [TS 32.297]
  TC-11: Per-session charging identifier (Charging-Id)     [TS 32.251]
  TC-12: Charging coverage summary

Feature: LI Readiness (--feature li_presence)
  TC-1:  ADMF (Administration Function) present           [TS 33.127]
  TC-2:  X1 provisioning interface (ADMF->POI)            [TS 33.128]
  TC-3:  IRI-POI host in MME (IRI event source)           [TS 33.127]
  TC-4:  CC-POI host in S-/P-GW (content of comms)        [TS 33.127]
  TC-5:  DF2/MDF2 (IRI mediation+delivery) + X2           [TS 33.128]
  TC-6:  DF3/MDF3 (CC mediation+delivery) + X3            [TS 33.128]
  TC-7:  HI1 (warrant/administrative) handover            [TS 33.108]
  TC-8:  HI2 (IRI delivery) handover to LEMF              [TS 33.108]
  TC-9:  HI3 (CC delivery) handover to LEMF               [TS 33.108]
  TC-10: LI domain security isolation / audit             [TS 33.126]
  TC-11: Target-identifier basis (IMSI/IMEI/MSISDN)       [TS 33.107]
  TC-12: LI architecture coverage summary

Feature: Interface Evidence (--feature interface_evidence)
  TC-1:  Docker control-plane evidence access
  TC-2:  tcpdump toolchain and pcap artifact directory
  TC-3:  DNS packet capture artifact
  TC-4:  S1-MME SCTP endpoint evidence
  TC-5:  PFCP/GTP-U endpoint evidence
  TC-6:  IMS SIP endpoint evidence
  TC-7:  SIP packet capture artifact
  TC-8:  [REAL-HW] External S1/NAS/SIP pcap attachment

============================================================
  Core suite:   22 features (default run)
  TRL8 add-on:  12 features (opt-in)
  Total:        34 features; runtime summary reports exact test-case totals
============================================================
EOF
}

show_help() {
    cat <<'EOF'
Usage: run_tests.sh [OPTIONS]

4G EPC + IMS Comprehensive Integration Test Suite

Options:
  --feature, -f NAME    Run only the specified feature
  --bundle, -b NAME     Run a curated bundle (tec, trl8, all)
  --test, -t NUM        Run only the specified test case (requires --feature)
  --list, -l            List all features and test cases
  --help, -h            Show this help message

Available features:
  epc_health    Dedicated EPC/IMS health checks (20 TCs) - runs FIRST
  hss_auc       HSS/AUC authentication, SQN, and IMS AKA tests (10 TCs)
  pdn_session   PDN session/APN/default-bearer tests (9 TCs)
  pyhss_api     PyHSS REST negative-input tests (10 TCs)
  attach_churn  Attach/detach lifecycle churn tests (9 TCs)
  regression    Interface health + E2E regression (49 TCs)
  volte         VoLTE readiness + intra/inter-NIB call tests (9 TCs)
  vilte         ViLTE media/control-plane + intra/inter-NIB call tests (11 TCs)
  eir           PyHSS/EIR provisioning and verification tests (6 TCs)
  sms           SMS over IMS — intra/inter-NIB + store-and-forward (offline) tests (13 TCs)
  inter_nib     Inter-NIB infrastructure: I-CSCF routing, DNS, INVITE (8 TCs)
  conference    Conference + conf-factory + inter-NIB + single 24-audio/8-video conference soak (15 TCs)
  fxo_fxs       External SIP breakout / FXO-FXS path tests (5 TCs)
  mobile_ip     Same-IMS mobile-to-softphone tests (6 TCs)
  cdr           Call Detail Record tests (7 TCs)
  load          Load/capacity + data-plane throughput tests (11 TCs)
  mms           MMS messaging tests — intra/inter-NIB (18 TCs)
  stress        Stability and extreme-condition tests (8 TCs)
  bearer_qos    QCI bearer lifecycle + Rx AAR tests (10 TCs)
  tec           TEC readiness evidence/gap matrix (13 TCs)
  advanced_sip  Advanced SIP: RTP echo, DTMF, REFER, emergency, IPv6 (5 TCs)
  security      Security posture: auth, input validation, RFC compliance, DoS (10 TCs)

TRL8 conformance/assurance add-on (opt-in — not in default run or 'tec'):
  nas_conformance  NAS/EMM/ESM conformance + security policy (10 TCs) [TS 24.301/33.401]
  scas_itsar       SCAS/ITSAR security hardening posture (12 TCs) [TS 33.117/33.210/ITSAR]
  diameter_conformance  Diameter protocol conformance — S6a/Cx/Rx (12 TCs) [RFC 6733/TS 29.272]
  pfcp_n4               PFCP conformance — Sxa/Sxb association, rules (12 TCs) [TS 29.244]
  s1ap                  S1AP conformance — S1 Setup, UE context, SCTP (12 TCs) [TS 36.413]
  ims_ng114             IMS IR.92/94 profile — IPSec, codecs (AMR-WB/H264), media (12 TCs) [IR.92/IR.94]
  perf_kpi              Performance KPI — API/DNS latency p50/p95, evidence matrix (12 TCs) [TS 28.554]
  ha_resilience         HA/restoration — NF restart recovery, PFCP restoration (12 TCs) [TS 23.527] (restarts NFs)
  oam_fcaps             OAM/FCAPS — PM metrics, Prometheus, fault, Grafana (12 TCs) [TS 28.552/28.545]
  charging              Charging — Gx control, CDR, URR, OCS/CGF posture (12 TCs) [TS 32.251/32.299]
  li_presence           Lawful Interception readiness — ADMF/MDF/POI/X1-X2-X3/HI posture (12 TCs) [TS 33.127/33.128]
  interface_evidence    Interface evidence pcaps, endpoint proof, real-HW pcap gate (8 TCs) [TRL8]

Available bundles:
  tec         Runs 4G TEC dry-run evidence coverage, then generates TEC gap matrix
  trl8        TRL8 conformance & assurance add-on features only
  all         All core features + trl8 (everything)

Examples:
  ./run_tests.sh                          # Run default core tests
  ./run_tests.sh --feature volte          # Run VoLTE tests only
  ./run_tests.sh --feature cdr --test 3   # Run CDR test case 3 only
  ./run_tests.sh --bundle tec             # Run TEC dry-run bundle
  ./run_tests.sh --list                   # List all features and test cases
EOF
}

run_feature_by_key() {
    local wanted="$1"
    local found=false
    local entry key func name
    for entry in "${FEATURES[@]}" "${TRL8_FEATURE_MAP[@]}"; do
        IFS=':' read -r key func name <<< "$entry"
        if [ "$key" == "$wanted" ]; then
            log "Running feature: $name"
            $func
            found=true
            break
        fi
    done
    if ! $found; then
        return 1
    fi
    return 0
}

# Wait for services to become available
wait_for_services() {
    log "Waiting for services to become available..."

    # Wait for P-CSCF
    wait_for_service "$PCSCF_IP" "$PCSCF_PORT" 60 "P-CSCF"

    # Wait for I-CSCF
    wait_for_service "$ICSCF_IP" 4060 60 "I-CSCF"

    # Wait for S-CSCF
    wait_for_service "$SCSCF_IP" 6060 60 "S-CSCF"

    # Wait for FreeSWITCH
    wait_for_service "$FREESWITCH_IP" 5090 60 "FreeSWITCH"

    # Wait for PyHSS API
    log "Waiting for PyHSS API at ${PYHSS_IP}:8080 (timeout: 60s)..."
    local elapsed=0
    while [ "$elapsed" -lt 60 ]; do
        if curl -s "http://${PYHSS_IP}:8080/apn/list" > /dev/null 2>&1; then
            log "PyHSS API is available"
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    if [ "$elapsed" -ge 60 ]; then
        log "WARNING: PyHSS API not reachable after 60s"
    fi

    # Wait for DNS
    log "Waiting for DNS at ${DNS_IP}:53 (timeout: 30s)..."
    elapsed=0
    while [ "$elapsed" -lt 30 ]; do
        if dig +short ${IMS_DOMAIN} @${DNS_IP} > /dev/null 2>&1; then
            log "DNS is available"
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    if [ "$elapsed" -ge 30 ]; then
        log "WARNING: DNS not reachable after 30s"
    fi

    log "Service readiness check complete"
}

# Provision test subscribers
provision_subscribers() {
    log "Provisioning test subscribers..."
    IMS_DOMAIN=$IMS_DOMAIN PYHSS_IP=$PYHSS_IP /opt/test/provision_subscribers.sh 2>&1 || true
    log "Provisioning done (duplicates are OK)"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --feature|-f) FEATURE="$2"; shift 2 ;;
        --bundle|-b) BUNDLE="$2"; shift 2 ;;
        --test|-t) TEST_NUM="$2"; shift 2 ;;
        --list|-l) show_list; exit 0 ;;
        --help|-h) show_help; exit 0 ;;
        *) echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

_SELECTED_TEST=$TEST_NUM

if [ -n "$FEATURE" ] && [ -n "$BUNDLE" ]; then
    echo "Use either --feature or --bundle, not both."
    exit 1
fi

if [ -n "$BUNDLE" ] && [ "$TEST_NUM" -ne 0 ]; then
    echo "--test is only supported with --feature."
    exit 1
fi

# Initialize the suite
init_suite

# Print banner
echo "================================================================"
echo "  4G EPC + IMS Comprehensive Integration Test Suite"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"
echo ""
log "Configuration:"
log "  P-CSCF:      ${PCSCF_IP}:${PCSCF_PORT}"
log "  FreeSWITCH:  ${FREESWITCH_IP}"
log "  PyHSS:       ${PYHSS_IP}"
log "  DNS:         ${DNS_IP}"
log "  I-CSCF:      ${ICSCF_IP}"
log "  S-CSCF:      ${SCSCF_IP}"
log "  SMSC:        ${SMSC_IP}"
log "  RTPengine:   ${RTPENGINE_IP}"
log "  MMSC:        ${MMSC_IP}"
log "  Local IP:    ${LOCAL_IP}"
log "  IMS Domain:  ${IMS_DOMAIN}"
log "  Topology:    ${TEST_TOPOLOGY} (${CORE_TARGET_LABEL})"
if [ -n "$CORE_VM_HOST" ]; then
    log "  Core VM:     ${CORE_VM_HOST}"
fi
log "  Docker host: ${DOCKER_HOST_LABEL}"
if [ "$TEST_TOPOLOGY" = "external" ]; then
    log "  Generator:   source=${LOCAL_IP_SOURCE}, LOAD_GENERATOR_IP=${LOAD_GENERATOR_IP:-unset}"
    if [ -z "$_LOCAL_IP_WAS_SET" ] && [ "$LOCAL_IP_SOURCE" = "default" ]; then
        log "  WARNING: TEST_TOPOLOGY=external but LOCAL_IP was not set and could not be auto-detected"
    fi
    if [ "${DOCKER_HOST:-unix:///var/run/docker.sock}" = "unix:///var/run/docker.sock" ]; then
        log "  NOTE: Docker evidence uses the local Docker daemon; set DOCKER_HOST for remote core container evidence"
    fi
fi
log ""

wait_for_services
provision_subscribers

if [ -n "$BUNDLE" ]; then
    case "$BUNDLE" in
        tec)
            for key in "${TEC_BUNDLE_FEATURES[@]}"; do
                if ! run_feature_by_key "$key"; then
                    echo "Internal error: TEC bundle references unknown feature '$key'"
                    exit 1
                fi
            done
            ;;
        trl8)
            for key in "${BUNDLE_TRL8_FEATURES[@]}"; do
                if ! run_feature_by_key "$key"; then
                    echo "Internal error: bundle 'trl8' references unknown feature '$key'"
                    exit 1
                fi
            done
            ;;
        all)
            # Heavy capacity features (load, stress) run at the END so their
            # signalling/log churn can't disturb earlier evidence features (mirrors
            # 5G). 'tec' is placed right after them because its certification matrix
            # READS the Load Test + Stress Test reports, so it must follow both.
            _baf_tail=()
            for _baf in "${BUNDLE_ALL_FEATURES[@]}"; do
                case "$_baf" in load|stress|tec) ;; *) _baf_tail+=("$_baf") ;; esac
            done
            BUNDLE_ALL_FEATURES=( "${_baf_tail[@]}" load stress tec )
            for key in "${BUNDLE_ALL_FEATURES[@]}"; do
                if ! run_feature_by_key "$key"; then
                    echo "Internal error: bundle 'all' references unknown feature '$key'"
                    exit 1
                fi
            done
            ;;
        *)
            echo "Unknown bundle: $BUNDLE"
            echo "Available bundles: tec, trl8, all"
            exit 1
            ;;
    esac
elif [ -z "$FEATURE" ]; then
    # Run default core features including load tests
    for entry in "${FEATURES[@]}"; do
        IFS=':' read -r key func name <<< "$entry"
        log "Running feature: $name"
        $func
    done
else
    # Run specific feature
    if ! run_feature_by_key "$FEATURE"; then
        echo "Unknown feature: $FEATURE"
        echo "Available: epc_health, hss_auc, pdn_session, pyhss_api, attach_churn, regression, volte, vilte, eir, sms, inter_nib, conference, fxo_fxs, mobile_ip, cdr, load, mms, stress, bearer_qos, tec, advanced_sip, security, nas_conformance, scas_itsar, diameter_conformance, pfcp_n4, s1ap, ims_ng114, perf_kpi, ha_resilience, oam_fcaps, charging, li_presence, interface_evidence"
        exit 1
    fi
fi

generate_summary

# Print summary
cat "$REPORT_DIR/summary.txt"

# Comprehensive report (auto) - ONLY on --bundle all; never for a single
# --feature/--test or the tec/trl8 bundles. Read-only consumer of reports/*;
# non-fatal so it can never affect the suite exit status or any test outcome.
if [ "$BUNDLE" = "all" ] && [ -f /opt/test/lib/comprehensive_report.py ]; then
    echo ""
    echo "Generating comprehensive 4G report (reports/comprehensive/)..."
    python3 /opt/test/lib/comprehensive_report.py 4g "$REPORT_DIR" \
        || echo "WARN: comprehensive report generation failed (non-fatal)"
fi

# Exit with failure if any test failed
if [ $_GLOBAL_FAIL -gt 0 ]; then
    exit 1
else
    exit 0
fi
