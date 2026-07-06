#!/bin/bash
# 5G SA + VoNR Comprehensive Integration Test Suite
# Usage:
#   ./run_tests_5g.sh                              # Run default core tests
#   ./run_tests_5g.sh --feature vonr               # Run VoNR tests only
#   ./run_tests_5g.sh --feature cdr_5g --test 3    # Run CDR TC-3 only
#   ./run_tests_5g.sh --bundle 5gc                 # Run 5GC core-only bundle
#   ./run_tests_5g.sh --list                       # List all features and test cases

set +e

normalize_shell_scripts() {
    find /opt/test -type f -name "*.sh" -exec sed -i 's/\r$//' {} + 2>/dev/null || true
}

normalize_shell_scripts

source /opt/test/lib/common_5g.sh
source /opt/test/lib/sipp_helpers.sh
source /opt/test/lib/ueransim_load_5g.sh

# Source all 5G feature scripts
source /opt/test/features/5g/01_5gc_health.sh
source /opt/test/features/5g/02_nrf_sbi.sh
source /opt/test/features/5g/03_ausf_udm.sh
source /opt/test/features/5g/04_5g_registration.sh
source /opt/test/features/5g/05_pdu_session.sh
source /opt/test/features/5g/05_pdu_profile_5g.sh
source /opt/test/features/5g/06_vonr.sh
source /opt/test/features/5g/07_sms_5g.sh
source /opt/test/features/5g/08_cdr_5g.sh
source /opt/test/features/5g/09_slicing.sh
source /opt/test/features/5g/10_load_5g.sh
source /opt/test/features/5g/11_security_5g.sh
source /opt/test/features/5g/12_regression_5g.sh
source /opt/test/features/5g/13_mms_5g.sh
source /opt/test/features/5g/14_conference_5g.sh
source /opt/test/features/5g/15_advanced_sip_5g.sh
source /opt/test/features/5g/16_stress_5g.sh
source /opt/test/features/5g/17_video_vonr_5g.sh
source /opt/test/features/5g/17_qos_flow_5g.sh

# TRL8 conformance/assurance add-on features (opt-in; see --bundle trl8)
source /opt/test/features/5g/18_nas_conformance_5g.sh
source /opt/test/features/5g/19_scas_itsar_5g.sh
source /opt/test/features/5g/20_sbi_conformance_5g.sh
source /opt/test/features/5g/21_pfcp_n4_5g.sh
source /opt/test/features/5g/22_ngap_n2_5g.sh
source /opt/test/features/5g/23_ims_ng114_5g.sh
source /opt/test/features/5g/24_perf_kpi_5g.sh
source /opt/test/features/5g/25_ha_resilience_5g.sh
source /opt/test/features/5g/26_oam_fcaps_5g.sh
source /opt/test/features/5g/27_charging_5g.sh
source /opt/test/features/5g/28_li_presence_5g.sh
source /opt/test/features/5g/29_interface_evidence_5g.sh

# Parse arguments
FEATURE=""
TEST_NUM=0
BUNDLE=""

# Map feature names to functions
FEATURES=(
    "regression_5g:run_regression_5g_tests:Regression (5G)"
    "5gc_health:run_5gc_health_tests:5GC Health"
    "nrf_sbi:run_nrf_sbi_tests:NRF & SBI"
    "ausf_udm:run_ausf_udm_tests:AUSF/UDM Auth"
    "registration:run_registration_tests:5G Registration"
    "pdu_session:run_pdu_session_tests:PDU Session"
    "pdu_profile_5g:run_pdu_profile_5g_tests:PDU Profile (5G)"
    "vonr:run_vonr_tests:VoNR"
    "sms_5g:run_sms_5g_tests:SMS over 5GS"
    "cdr_5g:run_cdr_5g_tests:CDR (5G)"
    "slicing:run_slicing_tests:Network Slicing"
    "load_5g:run_load_5g_tests:Load Test (5G)"
    "security_5g:run_security_5g_tests:Security (5G)"
    "mms_5g:run_mms_5g_tests:MMS over 5GS"
    "conference_5g:run_conference_5g_tests:Conference (5G VoNR)"
    "advanced_sip_5g:run_advanced_sip_5g_tests:Advanced SIP (5G VoNR)"
    "stress_5g:run_stress_5g_tests:Stress Test (5G VoNR)"
    "video_vonr:run_video_vonr_tests:Video VoNR (ViNR)"
    "qos_flow_5g:run_qos_flow_5g_tests:QoS Flow (5G)"
)

# 5GC core-only bundle: health + SBI + auth — fast smoke test, no UERANSIM needed
BUNDLE_5GC_FEATURES=(
    "regression_5g"
    "5gc_health"
    "nrf_sbi"
    "ausf_udm"
    "slicing"
)

# Full core bundle: all 19 core features
BUNDLE_FULL_FEATURES=(
    "regression_5g"
    "5gc_health"
    "nrf_sbi"
    "ausf_udm"
    "registration"
    "pdu_session"
    "pdu_profile_5g"
    "vonr"
    "sms_5g"
    "cdr_5g"
    "slicing"
    "security_5g"
    "mms_5g"
    "load_5g"
    "conference_5g"
    "advanced_sip_5g"
    "stress_5g"
    "video_vonr"
    "qos_flow_5g"
)

# ============================================================
# TRL8 conformance & assurance add-on (opt-in). Kept OUT of the default
# no-arg run and the 'full' bundle, keeping deployment/core validation
# separate from release-assurance coverage. Exposed via --feature <key>, --bundle trl8,
# and --bundle all.
# ============================================================
TRL8_FEATURE_MAP=(
    "nas_conformance_5g:run_nas_conformance_5g_tests:NAS Conformance (5G)"
    "scas_itsar_5g:run_scas_itsar_5g_tests:SCAS/ITSAR Security (5G)"
    "sbi_conformance_5g:run_sbi_conformance_5g_tests:SBI Conformance (5G)"
    "pfcp_n4_5g:run_pfcp_n4_5g_tests:PFCP/N4 Conformance (5G)"
    "ngap_n2_5g:run_ngap_n2_5g_tests:NGAP/N2 Conformance (5G)"
    "ims_ng114_5g:run_ims_ng114_5g_tests:IMS Profile NG.114 (5G)"
    "perf_kpi_5g:run_perf_kpi_5g_tests:Performance KPI (5G)"
    "ha_resilience_5g:run_ha_resilience_5g_tests:HA / Resilience (5G)"
    "oam_fcaps_5g:run_oam_fcaps_5g_tests:OAM / FCAPS (5G)"
    "charging_5g:run_charging_5g_tests:Charging (5G)"
    "li_presence_5g:run_li_presence_5g_tests:LI Readiness (5G)"
    "interface_evidence_5g:run_interface_evidence_5g_tests:Interface Evidence (5G)"
)

BUNDLE_TRL8_FEATURES=(
    "nas_conformance_5g"
    "scas_itsar_5g"
    "sbi_conformance_5g"
    "pfcp_n4_5g"
    "ngap_n2_5g"
    "ims_ng114_5g"
    "perf_kpi_5g"
    "oam_fcaps_5g"
    "charging_5g"
    "li_presence_5g"
    "interface_evidence_5g"
    "ha_resilience_5g"
)

# Everything: core 'full' + TRL8 add-on. Capacity features load_5g + stress_5g
# run near the end: their multi-UE PDU-session churn floods SMF/UPF logs, which
# would otherwise scroll out evidence used by later log-grep conformance tests.
# HA/resilience runs last because it intentionally restarts NFs and can disrupt
# the live UERANSIM dataplane needed by earlier load/PDU checks.
BUNDLE_ALL_FEATURES=()
for _baf in "${BUNDLE_FULL_FEATURES[@]}" "${BUNDLE_TRL8_FEATURES[@]}"; do
    case "$_baf" in
        load_5g|stress_5g|ha_resilience_5g) ;;
        *) BUNDLE_ALL_FEATURES+=("$_baf") ;;
    esac
done
BUNDLE_ALL_FEATURES+=("load_5g" "stress_5g" "ha_resilience_5g")

show_list() {
    cat <<'EOF'
============================================================
  5G SA + VoNR Integration Test Suite - Test Catalog
============================================================

Feature: Regression (--feature regression_5g)
  Cat 1: 5GC Container Health
  TC-1:  All 5GC NF containers running
  TC-2:  All IMS containers running
  TC-3:  All infrastructure containers running
  TC-4:  No container restart loops
  Cat 2: SBI Interface Health
  TC-5:  NRF SBI port reachable
  TC-6:  NRF nnrf-nfm API accessible
  TC-7:  All 5G NF SBI ports reachable
  TC-8:  5G NFs registered with NRF (7 NF types)
  Cat 3: 5G Data Plane (N4/N3)
  TC-9:  SMF-UPF PFCP N4 association
  TC-10: UPF TUN interface created
  TC-11: MongoDB port reachable
  Cat 4: IMS Signaling Chain
  TC-12: P-CSCF SIP port reachable
  TC-13: P-CSCF Kamailio health
  TC-14: PyHSS REST API reachable
  TC-15: DNS resolves IMS domain
  Cat 5: Full E2E VoNR Flow
  TC-16: E2E VoNR INVITE (intra-NIB)
  TC-17: FreeSWITCH Sofia profiles running
  Cat 6: Negative / Error Handling
  TC-18: UDM 404 for non-existent SUPI
  TC-19: PyHSS 404 for non-existent IMSI
  TC-20: NRF 404 for unknown NF instance DELETE
  Cat 7: 5G Subscriber Lifecycle
  TC-21: MongoDB subscriber collection exists
  TC-22: MongoDB has provisioned subscriber(s)
  TC-23: PyHSS subscriber list API working

Feature: 5GC Health (--feature 5gc_health)
  TC-1:  AMF running + NGAP port 38412
  TC-2:  SMF running
  TC-3:  UPF running + GTP-U port 2152
  TC-4:  NRF running + SBI port 7777
  TC-5:  SCP running
  TC-6:  AUSF running
  TC-7:  UDM running
  TC-8:  UDR running
  TC-9:  PCF running
  TC-10: BSF running
  TC-11: NSSF running
  TC-12: MongoDB running and ping OK
  TC-13: P-CSCF running
  TC-14: I-CSCF running
  TC-15: S-CSCF running
  TC-16: FreeSWITCH running
  TC-17: PyHSS running
  TC-18: MySQL running
  TC-19: DNS running
  TC-20: No restart loops

Feature: NRF & SBI (--feature nrf_sbi)
  TC-1:  NRF SBI port 7777 reachable
  TC-2:  NRF nf-instances API accessible
  TC-3:  AMF registered with NRF
  TC-4:  SMF registered with NRF
  TC-5:  AUSF registered with NRF
  TC-6:  UDM registered with NRF
  TC-7:  PCF registered with NRF
  TC-8:  NSSF registered with NRF
  TC-9:  BSF registered with NRF
  TC-10: SCP SBI port reachable

Feature: AUSF/UDM Auth (--feature ausf_udm)
  TC-1:  MongoDB port 27017 reachable
  TC-2:  UDR SBI port reachable
  TC-3:  UDM SBI port reachable
  TC-4:  AUSF SBI port reachable
  TC-5:  MongoDB 'open5gs' database exists
  TC-6:  UDM nudm-uecm API accessible
  TC-7:  AUSF nausf-auth API accessible
  TC-8:  WebUI port 9999 reachable

Feature: 5G Registration (--feature registration)
  TC-1:  AMF NGAP SCTP port 38412
  TC-2:  AMF SBI reachable
  TC-3:  AMF PLMN in NRF profile
  TC-4:  UERANSIM nr-gnb running
  TC-5:  UERANSIM nr-ue running
  TC-6:  gNB NG Setup completed
  TC-7:  UE Registration Request sent
  TC-8:  UE Registration Accepted
  TC-9:  AMF UE context processed

Feature: PDU Session (--feature pdu_session)
  TC-1:  SMF PFCP port 8805
  TC-2:  UPF PFCP port 8805
  TC-3:  SMF-UPF PFCP association established
  TC-4:  UPF GTP-U port 2152
  TC-5:  UPF TUN interface created
  TC-6:  PDU session log evidence in SMF
  TC-7:  UPF user-plane connectivity via UE PDU-session tunnel

Feature: PDU Profile (5G) (--feature pdu_profile_5g)
  TC-1:  SMF internet/IMS DNN profiles with IPv4/IPv6 pools
  TC-2:  UPF internet/IMS DNN profiles with data devices
  TC-3:  MongoDB subscriber internet/IMS DNN sessions
  TC-4:  UERANSIM UE internet DNN + S-NSSAI profile
  TC-5:  internet DNN PDU tunnel/address evidence
  TC-6:  IMS DNN readiness for VoNR
  TC-7:  IPv4v6 posture across core, subscriber, and UE profile
  TC-8:  Unsupported-DNN negative-probe readiness/gate
  TC-9:  PDU release/delete evidence
  TC-10: AMF/SMF/UPF post-profile health

Feature: QoS Flow (5G) (--feature qos_flow_5g)
  TC-1:  Subscriber internet 5QI=9 and IMS 5QI=5 profiles
  TC-2:  SMF internet/IMS DNN QoS and P-CSCF policy data
  TC-3:  PCF SM-policy SBI endpoint
  TC-4:  SMF-PCF policy association evidence
  TC-5:  Default QoS flow/PDU tunnel active for internet DNN
  TC-6:  IMS signaling QoS profile ready for VoNR
  TC-7:  IMS policy control path from P-CSCF/PCF
  TC-8:  PFCP QoS-rule/QER/QFI evidence or debug/pcap gate
  TC-9:  Light user-plane continuity over the QoS flow
  TC-10: Real-HW QoS scheduler/KPI evidence gate

Feature: VoNR (--feature vonr)
  TC-1:  DNS P-CSCF A record
  TC-2:  DNS I-CSCF SRV record
  TC-3:  DNS S-CSCF SRV record
  TC-4:  P-CSCF SIP port 5060
  TC-5:  S-CSCF SIP port 6060
  TC-6:  I-CSCF SIP port 4060
  TC-7:  RTPEngine health
  TC-8:  FreeSWITCH ESL health
  TC-9:  Intra-NIB VoNR INVITE
  TC-10: Inter-NIB VoNR INVITE
  TC-11: PCF N5 interface reachable

Feature: SMS over 5GS (--feature sms_5g)
  TC-1:  SMSC DNS resolution
  TC-2:  SMSC SRV record
  TC-3:  SMSC SIP port reachable
  TC-4:  SIP MESSAGE direct to SMSC
  TC-5:  MySQL SMSC database
  TC-6:  Intra-NIB SIP MESSAGE via IMS chain
  TC-7:  SMS delivery confirmation (MySQL)
  TC-8:  Inter-NIB SMS routing
  TC-9:  SMS body integrity
  TC-10: Store-and-forward — VoNR SMS to offline recipient stored + queued (pending_ue) + retained
  TC-11: USER_ONLINE trigger (S-CSCF re-register signal) flushes pending_ue
  TC-12: 48-hour expiry — over-age stored SMS discarded
  TC-13: Invalid-recipient guard — SMS to a non-MSISDN (e.g. 8-digit) is rejected before storage

Feature: CDR (5G) (--feature cdr_5g)
  TC-1:  CDR log file exists
  TC-2:  CDR htable configured
  TC-3:  CDR entry after VoNR call
  TC-4:  CDR fields validation
  TC-5:  CDR audio/call type
  TC-6:  CDR logrotate config
  TC-7:  CDR field completeness

Feature: Network Slicing (--feature slicing)
  TC-1:  NSSF SBI port reachable
  TC-2:  NSSF nnssf-nsselection API
  TC-3:  NSSF registered with NRF
  TC-4:  Default S-NSSAI SST=1 in config
  TC-5:  AMF NF profile slice list
  TC-6:  SMF S-NSSAI binding in NRF
  TC-7:  UPF DNN/slice config

Feature: Load Test (5G) (--feature load_5g)
  TC-1:  gNB NGAP connection ramp
  TC-2:  NRF API throughput
  TC-3:  UDM API throughput
  TC-4:  MongoDB read throughput
  TC-5:  UPF user-plane flow via UE PDU-session tunnel
  TC-6:  Voice-grade jitter measurement
  TC-7:  Concurrent SIP INVITE load
  TC-8:  UE registration burst (UERANSIM)
  TC-9:  UE registration capacity ramp (1->128 concurrent, real NAS reg + PDU)
  TC-10: Registration headroom (256 single-process) + core resource at peak
  TC-11: Sharded registration burst to the 4G-matched 512 target
  TC-12: PDU session establishment capacity (1 per registered UE)
  TC-13: Concurrent VoNR INVITE signaling capacity (SIPp over the shared IMS)
  TC-14: gNB NG-Setup capacity (concurrent dedicated load cells)        [4G eNB-capacity parity]
  TC-15: DNS query throughput (shared IMS resolver)                     [4G DNS-throughput parity]
  TC-16: Concurrent multi-flow PDU (internet 5QI-9 + IMS 5QI-5)         [4G QCI-9+QCI-5 parity]
  TC-17: VoNR call-establishment capacity (SIPp legs via FreeSWITCH)    [4G VoLTE call-pair parity]
  TC-18: ViNR video call-establishment capacity (audio+video SDP)       [4G ViLTE call-pair parity]
  TC-19: TCP data-plane ceiling sweep (REAL_HW-gated)                   [4G TCP-sweep parity]
  TC-20: UDP/RTP offered-load ceiling sweep (REAL_HW-gated)             [4G UDP-sweep parity]

Feature: Security (5G) (--feature security_5g)
  TC-1:  NRF rejects unknown NF de-registration
  TC-2:  UDM 404 for non-existent SUPI
  TC-3:  AUSF rejects malformed auth request
  TC-4:  MongoDB not exposed on host interface
  TC-5:  AMF NGAP DoS resilience
  TC-6:  Unauthenticated REGISTER -> 401
  TC-7:  INVITE to unknown subscriber -> 4xx
  TC-8:  SIP OPTIONS -> non-5xx
  TC-9:  Max-Forwards: 0 -> 483
  TC-10: P-CSCF alive after probes 1-9
  TC-11: Oversized Via header -> 4xx, no crash
  TC-12: Orphan BYE -> 481 (no active dialog)
  TC-13: Orphan CANCEL -> 481 (no active transaction)
  TC-14: Invalid SDP INVITE (no m= lines) -> 4xx/488

Feature: MMS over 5GS (--feature mms_5g)
  TC-1:  MMSC container running
  TC-2:  Kannel bearerbox port 13000
  TC-3:  Kannel smsbox port 13001
  TC-4:  Kannel sendsms HTTP port 13013
  TC-5:  Mbuni WAP gateway port 8090
  TC-6:  Mbuni SendMMS API port 8181
  TC-7:  Kannel admin status
  TC-8:  MMS notification path: HTTP→SMSC xhttp (port 7090, no SMPP/OsmoMSC)
  TC-9:  MMS storage volume mounted
  TC-10: MMS send via SendMMS API (basic smoke)
  TC-11: Kannel log health
  TC-12: Mbuni log health
  TC-13: MMS notification SMS path (SMPP -> SMSC -> IMS)
  TC-14: MMSC process health
  TC-15: MM7 incoming port 8190
  TC-16: Intra-NIB MMS send A->B (storage verified)
  TC-17: Intra-NIB MMS delivery queue
  TC-18: Inter-NIB MMS MM7 outbound

Feature: Conference (5G VoNR) (--feature conference_5g)
  TC-1:  DNS conf-factory resolution
  TC-2:  Direct FreeSWITCH VoNR conference (1010)
  TC-3:  P-CSCF VoNR conf-factory routing
  TC-4:  Direct FreeSWITCH video SDP conference (1010)
  TC-5:  P-CSCF video conf-factory routing
  TC-6:  Sequential conference rooms
  TC-7:  Multi-member VoNR conference join (4 members)
  TC-8:  Hold SDP via conf-factory
  TC-9:  Conference cleanup/room reuse
  TC-10: Concurrent VoNR conferences (two rooms)
  TC-11: PCF N5 QoS policy path for IMS sessions
  TC-12: PCF N5 SBI interface reachability
  TC-13: Inter-NIB conference INVITE (external domain)
  TC-14: 24-member SINGLE audio (VoNR) conference — join + sustained hold past rtp-timeout (stability primary; join count is in-suite ceiling, full N via real-UE/multi-host)
  TC-15: 8-member  SINGLE video (ViNR) conference — join + sustained hold (stability primary; real video media needs real UEs)

Feature: Advanced SIP (5G VoNR) (--feature advanced_sip_5g)
  TC-1:  RTP echo — UAC with -rtp_echo to FreeSWITCH (real media loopback)
  TC-2:  DTMF SIP INFO — in-call INFO with application/dtmf-relay
  TC-3:  REFER call transfer — IMS returns 202 + NOTIFY
  TC-4:  Emergency INVITE — sip:112@domain (non-5xx required)
  TC-5:  IPv6 signaling — REGISTER with IPv6 addresses (non-5xx required)

Feature: Stress Test (5G VoNR) (--feature stress_5g)
  TC-1:  P-CSCF resource configuration audit (SHM, IPSec, CDP)
  TC-2:  Concurrent VoNR calls under load (SIPp → FreeSWITCH)
  TC-3:  Long-duration VoNR call stability (session-timer resilience)
  TC-4:  Rx Diameter health under load (CDP threshold violations)
  TC-5:  P-CSCF shared memory utilization under load
  TC-6:  IPSec port exhaustion detection
  TC-7:  In-dialog AAR failure resilience (CRITICAL)
  TC-8:  Multi-call concurrent VoNR stability

Feature: Video VoNR / ViNR (--feature video_vonr)
  TC-1:  P-CSCF sdpops module loaded
  TC-2:  P-CSCF rtpengine module loaded
  TC-3:  PCF N5 video QoS flow authorization (5G QoS flows vs 4G dedicated bearers)
  TC-4:  P-CSCF video bandwidth config (b=AS for video SDP)
  TC-5:  RTPEngine reachability from P-CSCF
  TC-6:  RTPEngine process health and version
  TC-7:  S-CSCF video CDR detection configured
  TC-8:  P-CSCF audio codec transcoding flags
  TC-9:  Intra-NIB Video VoNR INVITE (audio+video SDP)
  TC-10: Inter-NIB Video VoNR INVITE (audio+video SDP, external domain)

------------------------------------------------------------
  TRL8 Conformance & Assurance add-on
  (opt-in: --bundle trl8 | --bundle all | --feature <key>;
   NOT part of the default run or the 'full' bundle)
------------------------------------------------------------

Feature: NAS Conformance (5G) (--feature nas_conformance_5g)
  TC-1:  AMF NGAP ready to transport NAS-5GS
  TC-2:  NAS integrity algorithm policy (NIA1/NIA2)        [TS 33.501]
  TC-3:  NAS ciphering algorithm capability (NEA1/NEA2)    [TS 33.501]
  TC-4:  5G-AKA authentication evidence (AUSF/UDM)         [TS 33.501]
  TC-5:  SUCI concealment / de-concealment evidence        [TS 33.501]
  TC-6:  NAS Security Mode Command/Complete evidence       [TS 24.501]
  TC-7:  Registration Accept + 5G-GUTI assignment          [TS 24.501]
  TC-8:  PDU Session Establishment (5GSM) evidence         [TS 24.501]
  TC-9:  De-registration / UE Context Release evidence     [TS 24.501]
  TC-10: Registration Reject 5GMM cause conformance        [TS 24.501]
  TC-11: Periodic registration timer T3512 configuration
  TC-12: [REAL-HW] Real gNB NG Setup + real UE 5G-AKA registration (REAL_HW=1)

Feature: SCAS/ITSAR Security (5G) (--feature scas_itsar_5g)
  TC-1:  No insecure remote-access services on 5GC NFs     [TS 33.117]
  TC-2:  No insecure services on IMS NFs + datastores      [TS 33.117]
  TC-3:  MongoDB authentication posture                    [ITSAR]
  TC-4:  MySQL credential posture (no passwordless root)   [ITSAR]
  TC-5:  SBI transport security (TLS on NRF SBI)           [TS 33.501]
  TC-6:  SBI NF-to-NF authorization (OAuth2)               [TS 33.501]
  TC-7:  Subscriber identity privacy (no clear SUPI/IMSI in logs)
  TC-8:  NFs run as non-root (least privilege)             [TS 33.117]
  TC-9:  N2/N3 transport protection (IPsec)                [TS 33.501]
  TC-10: SEPP present for inter-PLMN N32                   [TS 33.517]
  TC-11: Listening-port inventory evidence (attack surface)
  TC-12: ITSAR hardening posture summary (evidence emitter)

Feature: SBI Conformance (5G) (--feature sbi_conformance_5g)
  TC-1:  HTTP/2 transport on SBI (h2c prior-knowledge)     [TS 29.500]
  TC-2:  API URI versioning (/v1 valid; /v99 rejected)     [TS 29.501]
  TC-3:  NF profile mandatory IEs (id/type/status)         [TS 29.510]
  TC-4:  NFDiscover via nnrf-disc                          [TS 29.510]
  TC-5:  ProblemDetails on malformed discovery             [TS 29.500]
  TC-6:  404 discipline for unknown nf-instance            [TS 29.500]
  TC-7:  UDM SDM negative input -> 4xx, never 5xx          [TS 29.503]
  TC-8:  NRF subscription input validation (POST -> 4xx)   [TS 29.510]
  TC-9:  heartBeatTimer present in NF profiles             [TS 29.510]
  TC-10: Content-Type discipline on profile responses      [TS 29.500]
  TC-11: SCP indirect communication availability           [TS 29.500]
  TC-12: NRF stability after negative-input battery (guard)

Feature: PFCP/N4 Conformance (5G) (--feature pfcp_n4_5g)
  TC-1:  SMF PFCP server bound on N4 (8805/UDP)            [TS 29.244]
  TC-2:  UPF PFCP server bound on N4 (8805/UDP)            [TS 29.244]
  TC-3:  SMF<->UPF mutual PFCP association                  [TS 29.244]
  TC-4:  N4 node configuration audit (server/client)       [TS 29.244]
  TC-5:  PFCP request/response message exchange            [TS 29.244]
  TC-6:  PFCP association liveness / keepalive              [TS 29.244]
  TC-7:  UPF GTP-U N3 data plane bound (2152/UDP)          [TS 29.281]
  TC-8:  UPF packet-forwarding plane ready (TUN)           [N6]
  TC-9:  PFCP Session Establishment (N4) evidence          [TS 29.244]
  TC-10: PFCP rules PDR/FAR/QER installation evidence      [TS 29.244]
  TC-11: PFCP Usage Reporting (URR) for charging           [TS 29.244]
  TC-12: PFCP association restoration / recovery           [TS 23.527]

Feature: NGAP/N2 Conformance (5G) (--feature ngap_n2_5g)
  TC-1:  AMF NGAP SCTP transport bound (38412)             [TS 38.412]
  TC-2:  AMF NGAP config audit (PLMN/TAC/GUAMI/TAI)        [TS 38.413]
  TC-3:  NG Setup / gNB N2 association                      [TS 38.413]
  TC-4:  Initial UE Message (NAS over N2)                   [TS 38.413]
  TC-5:  NGAP UE identity management (RAN/AMF_UE_NGAP_ID)   [TS 38.413]
  TC-6:  UE Context Release procedure                       [TS 38.413]
  TC-7:  SCTP association multi-streaming (NGAP)            [TS 38.412]
  TC-8:  PDU Session Resource Setup (N2) evidence           [TS 38.413]
  TC-9:  Paging procedure                                   [TS 38.413]
  TC-10: Reset procedure handling                           [TS 38.413]
  TC-11: Error Indication / Overload handling               [TS 38.413]
  TC-12: [REAL-HW] Real gNB NG Setup + NGAP UE context (REAL_HW=1)

Feature: IMS Profile NG.114 (5G) (--feature ims_ng114_5g)
  TC-1:  P-CSCF IMS registrar capability                   [TS 24.229]
  TC-2:  IMS access-security: IPSec module loaded          [TS 33.203]
  TC-3:  IPSec SA parameters (SPI range + ports)           [TS 33.203]
  TC-4:  IPSec integrity/encryption posture (ealg)         [TS 33.203]
  TC-5:  IMS authentication enforced (REGISTER->401)       [NG.114]
  TC-6:  Mandatory voice codec AMR                         [NG.114]
  TC-7:  Mandatory wideband codec AMR-WB                   [NG.114]
  TC-8:  EVS codec (NG.114 primary 5G voice)               [NG.114]
  TC-9:  Video codec H.264 (ViNR)                          [IR.94]
  TC-10: Media plane: SDP manipulation + RTP anchoring     [NG.114]
  TC-11: IMS registration evidence                         [TS 24.229]
  TC-12: SIP reliable-provisional/precondition readiness   [RFC 3312]

Feature: Performance KPI (5G) (--feature perf_kpi_5g)
  TC-1:  SBI control-plane latency (NRF) p50/p95           [TS 28.554]
  TC-2:  SBI discovery latency (nnrf-disc) p50/p95         [TS 28.554]
  TC-3:  SBI request success-rate KPI                      [TS 28.554]
  TC-4:  Registration procedure latency (UERANSIM)         [TS 28.554]
  TC-5:  PDU session establishment latency                 [TS 28.554]
  TC-6:  User-plane round-trip latency (uesimtun0)         [TS 28.554]
  TC-7:  User-plane throughput (iperf3 via UE)             [TS 28.554]
  TC-8:  Registered-UE / PDU-session capacity snapshot     [TS 28.554]
  TC-9:  NF CPU/memory utilization (headroom)              [TS 28.554]
  TC-10: Control-plane latency stability under load        [TS 28.554]
  TC-11: Concurrent SBI request throughput (req/s)         [TS 28.554]
  TC-12: KPI evidence matrix (TS 28.554)

Feature: HA / Resilience (5G) (--feature ha_resilience_5g)   [** restarts NFs — run isolated/last **]
  TC-1:  UPF N4 PFCP restoration (recovery-timestamp+re-assoc) [TS 23.527]
  TC-2:  PFCP recovery-timestamp peer-restart detection        [TS 23.527]
  TC-3:  SMF restart -> N4 re-assoc + NRF re-registration       [TS 23.527]
  TC-4:  Stateless NF (AUSF) restart -> NRF re-registration     [TS 29.510]
  TC-5:  AMF restart recovery (NGAP re-bind + NRF re-reg)       [TS 23.527]
  TC-6:  NF crash-loop stability (RestartCount)                [robustness]
  TC-7:  NF clean re-initialization after restart              [TS 23.527]
  TC-8:  Data-store HA posture (replica set / failover)        [HA]
  TC-9:  PFCP heartbeat liveness / peer supervision            [TS 29.244]
  TC-10: Recovery time measurement (restart -> service back)   [KPI]
  TC-11: Restoration coverage (PFCP + NRF re-registration)     [TS 23.527]
  TC-12: HA / restoration evidence summary

Feature: OAM / FCAPS (5G) (--feature oam_fcaps_5g)
  TC-1:  PM: AMF metrics endpoint reachable (:9091)        [TS 28.552]
  TC-2:  PM: 3GPP 5G PM counters exported (fivegs_*)       [TS 28.552]
  TC-3:  PM: Prometheus/OpenMetrics format (HELP/TYPE)     [TS 28.552]
  TC-4:  PM: multiple NFs export metrics (AMF/SMF/UPF)     [TS 28.552]
  TC-5:  PM: Prometheus collector reachable + query API    [OAM]
  TC-6:  FM: per-NF target health via 'up' metric          [TS 28.545]
  TC-7:  FM: NF fault/error counters present               [TS 28.545]
  TC-8:  FM: NF crash/restart supervision (RestartCount)   [TS 28.545]
  TC-9:  CM: NF metrics configuration consistency (NRM)    [TS 28.541]
  TC-10: Visualization: Grafana dashboards reachable       [OAM]
  TC-11: Logging: NF structured logging accessible         [OAM]
  TC-12: OAM / FCAPS coverage summary

Feature: Charging (5G) (--feature charging_5g)
  TC-1:  Npcf SM-Policy + charging-rule linkage (SMF<->PCF) [TS 29.512]
  TC-2:  Converged Charging Function (CHF / Nchf)          [TS 32.290]
  TC-3:  PFCP N4 usage measurement (URR) for charging      [TS 32.255]
  TC-4:  IMS offline CDR mechanism                         [TS 32.260]
  TC-5:  PCF policy node present (N7/Npcf)                 [TS 23.503]
  TC-6:  Online/quota charging (Nchf credit control)       [TS 32.255]
  TC-7:  Offline charging / CDR aggregation (CHF)          [TS 32.297]
  TC-8:  5QI / charging-characteristics based rating       [TS 32.255]
  TC-9:  CDR field/format conformance                      [TS 32.298]
  TC-10: Charging data transfer to CHF (Nchf/Bc)           [TS 32.297]
  TC-11: Per-session charging identifier (Charging-Id)     [TS 32.255]
  TC-12: Charging coverage summary

Feature: LI Readiness (5G) (--feature li_presence_5g)
  TC-1:  ADMF (LICF+LIPF) present                         [TS 33.127]
  TC-2:  X1 provisioning interface (LIPF->POI)            [TS 33.128]
  TC-3:  IRI-POI host in AMF (IRI event source)           [TS 33.127]
  TC-4:  CC-POI host in UPF (content of comms)            [TS 33.127]
  TC-5:  MDF2 (IRI mediation+delivery) + X2               [TS 33.128]
  TC-6:  MDF3 (CC mediation+delivery) + X3                [TS 33.128]
  TC-7:  HI1 (warrant/administrative) handover            [TS 33.128]
  TC-8:  HI2 (IRI delivery) handover to LEMF              [TS 33.128]
  TC-9:  HI3 (CC delivery) handover to LEMF               [TS 33.128]
  TC-10: LI domain security isolation / audit             [TS 33.126]
  TC-11: Target-identifier basis (SUPI/SUCI/PEI/GPSI)     [TS 33.127]
  TC-12: LI architecture coverage summary

Feature: Interface Evidence (5G) (--feature interface_evidence_5g)
  TC-1:  Docker control-plane evidence access
  TC-2:  tcpdump toolchain and pcap artifact directory
  TC-3:  NRF/SBI packet capture artifact
  TC-4:  N2/NGAP SCTP endpoint evidence
  TC-5:  N4/N3 PFCP/GTP-U endpoint evidence
  TC-6:  IMS SIP endpoint evidence
  TC-7:  SIP packet capture artifact
  TC-8:  [REAL-HW] External N2/NAS/SIP pcap attachment

============================================================
  Core suite:   19 features, 213 test cases
  TRL8 add-on:  12 features, 140 test cases  (opt-in)
  Total:        31 features, 353 test cases
============================================================
EOF
}

show_help() {
    cat <<'EOF'
Usage: run_tests_5g.sh [OPTIONS]

5G SA + VoNR Comprehensive Integration Test Suite

Options:
  --feature, -f NAME    Run only the specified feature
  --bundle, -b NAME     Run a curated bundle (5gc, full, trl8, all)
  --test, -t NUM        Run only the specified test case (requires --feature)
  --list, -l            List all features and test cases
  --help, -h            Show this help message

Available features:
  regression_5g  Full 5G regression (23 TCs) - runs FIRST
  5gc_health     5GC NF container health (20 TCs)
  nrf_sbi        NRF & SBI interface health (10 TCs)
  ausf_udm       AUSF/UDM auth + MongoDB (8 TCs)
  registration   5G UE registration via UERANSIM (9 TCs)
  pdu_session    PDU session + N4 PFCP + UPF data plane (7 TCs)
  pdu_profile_5g PDU/DNN profile, IPv4v6, release evidence (10 TCs)
  vonr           VoNR IMS signaling path (11 TCs)
  sms_5g         SMS over 5GS via IMS + store-and-forward (offline) (13 TCs)
  cdr_5g         Call Detail Records in 5G context (7 TCs)
  slicing        Network slice selection (NSSF) (7 TCs)
  load_5g        Load, throughput & capacity tests, 4G-parity (20 TCs)
  security_5g    Security posture — SBI + IMS (14 TCs)
  mms_5g         MMS over 5GS (Kannel + Mbuni via PDU session) (18 TCs)
  conference_5g  Conference over VoNR/ViNR — FreeSWITCH + P-CSCF + single 24-audio/8-video soak (15 TCs)
  advanced_sip_5g Advanced SIP: RTP echo, REFER, emergency, IPv6 (5 TCs)
  stress_5g      Stress/stability: P-CSCF load, in-dialog AAR (9 TCs)
  video_vonr     Video over NR (ViNR): IMS video path (10 TCs)
  qos_flow_5g    QoS Flow / 5QI lifecycle and policy path (10 TCs)

TRL8 conformance/assurance add-on (opt-in — not in default run or 'full'):
  nas_conformance_5g  NAS/5GMM/5GSM conformance + security policy (12 TCs) [TS 24.501/33.501]
  scas_itsar_5g       SCAS/ITSAR security hardening posture (12 TCs) [TS 33.117/33.501/ITSAR]
  sbi_conformance_5g  SBI protocol conformance — HTTP/2, ProblemDetails (12 TCs) [TS 29.500/29.510]
  pfcp_n4_5g          PFCP/N4 conformance — association, rules, GTP-U (12 TCs) [TS 29.244]
  ngap_n2_5g          NGAP/N2 conformance — NG Setup, UE context, SCTP (12 TCs) [TS 38.413]
  ims_ng114_5g        IMS NG.114 profile — IPSec, codecs (AMR-WB/EVS/H264), media (12 TCs) [NG.114]
  perf_kpi_5g         Performance KPI — latency p50/p95, success rate, evidence matrix (12 TCs) [TS 28.554]
  ha_resilience_5g    HA/restoration — NF restart recovery, PFCP restoration (12 TCs) [TS 23.527] (restarts NFs)
  oam_fcaps_5g        OAM/FCAPS — PM metrics, Prometheus, fault, Grafana (12 TCs) [TS 28.552/28.545]
  charging_5g         Charging — Npcf policy, CDR, URR, CHF/Nchf posture (12 TCs) [TS 32.255/32.290]
  li_presence_5g      Lawful Interception readiness — ADMF/MDF/POI/X1-X2-X3/HI posture (12 TCs) [TS 33.127/33.128]
  interface_evidence_5g Interface evidence pcaps, endpoint proof, real-HW pcap gate (8 TCs) [TRL8]

Available bundles:
  5gc     5GC core smoke test (no UERANSIM needed): regression_5g + 5gc_health + nrf_sbi + ausf_udm + slicing
  full    Full core bundle: all 19 core features
  trl8    TRL8 conformance & assurance add-on features only
  all     full + trl8 (everything)

Examples:
  ./run_tests_5g.sh                              # Run default core tests
  ./run_tests_5g.sh --feature vonr               # Run VoNR tests only
  ./run_tests_5g.sh --feature cdr_5g --test 3    # Run CDR TC-3 only
  ./run_tests_5g.sh --bundle 5gc                 # Run 5GC core-only smoke bundle
  ./run_tests_5g.sh --list                       # List all features
EOF
}

run_feature_by_key() {
    local wanted="$1"
    local found=false
    local entry key func name
    for entry in "${FEATURES[@]}" "${TRL8_FEATURE_MAP[@]}"; do
        IFS=':' read -r key func name <<< "$entry"
        if [ "$key" = "$wanted" ]; then
            log "Running feature: $name"
            $func
            found=true
            break
        fi
    done
    $found || return 1
    return 0
}

# Wait for 5G services to become available
wait_for_services() {
    log "Waiting for 5G services to become available..."

    wait_for_service "$NRF_IP" "$NRF_PORT" 60 "NRF"
    wait_for_service "$AMF_IP" "$AMF_SBI_PORT" 60 "AMF SBI"
    wait_for_service "$PCSCF_IP" "$PCSCF_PORT" 60 "P-CSCF"

    # Wait for MongoDB
    log "Waiting for MongoDB at ${MONGO_IP}:27017 (timeout: 60s)..."
    local elapsed=0
    while [ "$elapsed" -lt 60 ]; do
        if nc -z -w 2 "$MONGO_IP" 27017 2>/dev/null; then
            log "MongoDB is reachable"
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    # Wait for PyHSS API
    log "Waiting for PyHSS API at ${PYHSS_IP}:8080 (timeout: 60s)..."
    elapsed=0
    while [ "$elapsed" -lt 60 ]; do
        if curl -s "http://${PYHSS_IP}:8080/apn/list" > /dev/null 2>&1; then
            log "PyHSS API is available"
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log "Service readiness check complete"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --feature|-f) FEATURE="$2"; shift 2 ;;
        --bundle|-b)  BUNDLE="$2";  shift 2 ;;
        --test|-t)    TEST_NUM="$2"; shift 2 ;;
        --list|-l)    show_list; exit 0 ;;
        --help|-h)    show_help; exit 0 ;;
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
echo "  5G SA + VoNR Integration Test Suite"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"
echo ""
log "Configuration:"
log "  AMF:         ${AMF_IP}:${AMF_SBI_PORT} (SBI) / ${AMF_IP}:38412 (NGAP)"
log "  NRF:         ${NRF_IP}:${NRF_PORT}"
log "  AUSF:        ${AUSF_IP}:${AUSF_PORT}"
log "  UDM:         ${UDM_IP}:${UDM_PORT}"
log "  PCF:         ${PCF_IP}:${PCF_PORT}"
log "  UPF:         ${UPF_IP}"
log "  MongoDB:     ${MONGO_IP}:27017"
log "  P-CSCF:      ${PCSCF_IP}:${PCSCF_PORT}"
log "  PyHSS:       ${PYHSS_IP}"
log "  DNS:         ${DNS_IP}"
log "  FreeSWITCH:  ${FREESWITCH_IP}"
log "  IMS Domain:  ${IMS_DOMAIN}"
log "  Local IP:    ${LOCAL_IP}"
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

if [ -n "$BUNDLE" ]; then
    case "$BUNDLE" in
        5gc)
            for key in "${BUNDLE_5GC_FEATURES[@]}"; do
                run_feature_by_key "$key" || {
                    echo "Internal error: bundle '5gc' references unknown feature '$key'"
                    exit 1
                }
            done
            ;;
        full)
            for key in "${BUNDLE_FULL_FEATURES[@]}"; do
                run_feature_by_key "$key" || {
                    echo "Internal error: bundle 'full' references unknown feature '$key'"
                    exit 1
                }
            done
            ;;
        trl8)
            for key in "${BUNDLE_TRL8_FEATURES[@]}"; do
                run_feature_by_key "$key" || {
                    echo "Internal error: bundle 'trl8' references unknown feature '$key'"
                    exit 1
                }
            done
            ;;
        all)
            for key in "${BUNDLE_ALL_FEATURES[@]}"; do
                run_feature_by_key "$key" || {
                    echo "Internal error: bundle 'all' references unknown feature '$key'"
                    exit 1
                }
            done
            ;;
        *)
            echo "Unknown bundle: $BUNDLE"
            echo "Available bundles: 5gc, full, trl8, all"
            exit 1
            ;;
    esac
elif [ -z "$FEATURE" ]; then
    # Run default core features
    for entry in "${FEATURES[@]}"; do
        IFS=':' read -r key func name <<< "$entry"
        log "Running feature: $name"
        $func
    done
else
    if ! run_feature_by_key "$FEATURE"; then
        echo "Unknown feature: $FEATURE"
        echo "Available: regression_5g, 5gc_health, nrf_sbi, ausf_udm, registration, pdu_session, pdu_profile_5g, vonr, sms_5g, cdr_5g, slicing, load_5g, security_5g, mms_5g, conference_5g, advanced_sip_5g, stress_5g, video_vonr, qos_flow_5g, nas_conformance_5g, scas_itsar_5g, sbi_conformance_5g, pfcp_n4_5g, ngap_n2_5g, ims_ng114_5g, perf_kpi_5g, ha_resilience_5g, oam_fcaps_5g, charging_5g, li_presence_5g, interface_evidence_5g"
        exit 1
    fi
fi

generate_summary

cat "$REPORT_DIR/summary.txt"

# Comprehensive report (auto) - ONLY on --bundle all; never for a single
# --feature/--test or the tec/trl8 bundles. Read-only consumer of reports/*;
# non-fatal so it can never affect the suite exit status or any test outcome.
if [ "$BUNDLE" = "all" ] && [ -f /opt/test/lib/comprehensive_report.py ]; then
    echo ""
    echo "Generating comprehensive 5G report (reports/comprehensive/)..."
    python3 /opt/test/lib/comprehensive_report.py 5g "$REPORT_DIR" \
        || echo "WARN: comprehensive report generation failed (non-fatal)"
fi

if [ $_GLOBAL_FAIL -gt 0 ]; then
    exit 1
else
    exit 0
fi
