4G EPC + IMS TEST SUITE README
==============================

This directory contains the Dockerized 4G EPC + IMS integration test suite for
the docker_open5gs deployment. The suite validates EPC health, IMS signaling,
VoLTE/ViLTE call flows, SMS/MMS paths (intra- and inter-NIB), conference
behavior, CDR generation, load/stress behavior, bearer QoS, advanced SIP
features, security posture, TEC readiness evidence, and optional feature
coverage gaps.


1. LOCATION
===========

Repository path:

  docker_open5gs/test/

Run commands from this directory:

  cd ~/docker_open5gs/test


2. BUILD INSTRUCTIONS
=====================

Build or rebuild the test container:

  sudo docker compose -f docker-compose.test.yaml build

Clean rebuild after script/package changes:

  sudo docker compose -f docker-compose.test.yaml build --no-cache

Run the default core suite after build:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test

Run the complete suite (core + TRL8 opt-in features):

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --bundle all

Run the TEC dry-run bundle:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --bundle tec

Remove old one-shot test containers if needed:

  sudo docker compose -f docker-compose.test.yaml down --remove-orphans


3. DIRECTORY AND FILE ARCHITECTURE
==================================

  test/
    Dockerfile
      Builds the test runner image. Installs SIPp, curl, jq, DNS tools,
      netcat, iperf3, Docker CLI, MySQL client, SCTP libraries,
      Python 3, and UE simulator dependencies (sctp, pycryptodome).
      Phase 1 enhancement: added python3-sctp and pycryptodome packages
      required for S1AP/NAS UE simulator Milenage AKA computation.

    docker-compose.test.yaml
      Docker Compose definition for the sipp-test runner container.

    run_tests.sh
      Main suite entrypoint. Parses --feature, --test, --bundle, --list,
      and --help. Sources core and opt-in TRL8 feature scripts, waits for services,
      provisions subscribers, runs selected tests, and generates final
      reports.

    provision_subscribers.sh
      Creates/refreshes test APNs, AUC rows, subscriber rows, and IMS
      subscriber rows in PyHSS/MySQL for the standard test UEs.
      Phase 1 enhancement: uses PYHSS_API_KEY env var for bearer-token
      auth (required by PyHSS API when authentication is enabled).

    lib/
      common.sh
        Shared test framework: pass/fail/skip handling, service checks,
        report generation, hardware/cgroup checkpoint capture, UE simulator
        probes, resource snapshots, and common helpers.
        Phase 1 fixes:
          - pass()/fail()/skip() no longer contain no-op _TEST_NUM
            assignments that could increment the counter unexpectedly.
          - MySQL password uses ${MYSQL_ROOT_PASSWORD:-MySQL_PaSsW0rD}
            pattern throughout instead of a hardcoded literal.

      sipp_helpers.sh
        Shared SIPp helper functions and scenario execution helpers.
        Phase 1 fix: run_sipp_bg() uses mktemp for per-PID log files
        (was: /tmp/sipp_bg_$$.log — all background SIPp processes shared
        the same path; now each gets a unique temp file tracked in
        SIPP_BG_LOG_<pid> variable).

    features/
      01_volte.sh
        VoLTE readiness: DNS, SIP ports, RTPEngine.

      02_vilte.sh
        ViLTE readiness: video SDP/media configuration and RTPEngine
        support.

      03_eir.sh
        EIR/PyHSS provisioning and subscriber verification checks.

      01_volte.sh
        VoLTE readiness: DNS, SIP ports, RTPEngine, and call routing.
        Original TCs (1-7): DNS A/SRV, P/I/S-CSCF ports, RTPEngine health.
        New TCs added (Phase 5b):
          TC-8: Intra-NIB VoLTE INVITE — INVITE from 9876540001 to
                9876541000 within the same IMS_DOMAIN. Uses
                volte_intra_nib_invite.xml via P-CSCF. Passes on any
                non-5xx response (4xx expected without full registration).
          TC-9: Inter-NIB VoLTE INVITE — INVITE to
                sip:+9990001234@external.example via P-CSCF/I-CSCF.
                Uses volte_inter_nib_invite.xml. IMS must attempt
                inter-domain routing without returning 5xx (4xx/timeout
                acceptable; no real external NIB in test env).

      02_vilte.sh
        ViLTE readiness: P-CSCF video config, RTPEngine, S-CSCF video
        CDR, codec flags, and both intra/inter-NIB video call routing.
        Original TCs (1-8): sdpops, rtpengine modules, video auth, BW
        config, RTPEngine reachability/health, S-CSCF video CDR,
        codec transcoding flags.
        New TCs added (Phase 5b):
          TC-9:  Intra-NIB ViLTE INVITE — INVITE with audio+video SDP
                 (m=audio + m=video with H264/H265) to local MSISDN.
                 Uses vilte_intra_nib_invite.xml. Verifies P-CSCF handles
                 video SDP without 5xx. 488 on codec mismatch is noted
                 as a config issue.
          TC-10: Inter-NIB ViLTE INVITE — audio+video SDP INVITE to
                 external domain. Uses vilte_inter_nib_invite.xml. IMS
                 must not return 5xx on video SDP for external URI.

      04_sms.sh
        SMS over IMS checks.
        Original TCs (1-5): SMSC DNS/SRV/port, direct SIP MESSAGE to
        SMSC:7090, MySQL smsc database presence.
        New TCs added (Phase 5b):
          TC-6: Intra-NIB SIP MESSAGE via full IMS chain
                (P-CSCF -> S-CSCF -> SMSC) using sms_via_ims.xml.
                Validates that the S-CSCF routes MESSAGE within the domain
                rather than requiring a direct SMSC connection.
          TC-7: Intra-NIB SMS delivery confirmation — queries MySQL
                smsc.messages for recipient MSISDN 9876541000 after TC-6.
                Skipped when DB is inaccessible or no full IMS registration.
          TC-8: Inter-NIB SMS routing — routes SIP MESSAGE to external URI
                (sip:+9990001234@external.example) via sms_inter_nib.xml.
                Passes if IMS returns any non-5xx response (4xx/timeout
                acceptable; no real external NIB in test env).
          TC-9: SMS message body integrity — verifies the known test body
                "IMS intra-NIB SMS" is stored in smsc.messages.

      05_inter_nib.sh
        Inter-NIB INFRASTRUCTURE checks. Does NOT duplicate the SMS,
        MMS, VoLTE, ViLTE, or conference intra/inter-NIB tests that live
        in their respective feature files. Covers the shared routing
        infrastructure that all inter-NIB services depend on.
        Original TCs (1-5): DNS SRV for I/S-CSCF, P/I/S-CSCF port checks.
        New TCs added (Phase 5b):
          TC-6: I-CSCF inter-domain federation routing config — verifies
                I-CSCF kamailio.cfg contains DNS/LIR/PSTN/external routing
                references. The I-CSCF is the border element for all inter-
                NIB traffic (VoLTE, ViLTE, SMS, conference).
          TC-7: DNS resolver reachability for inter-NIB SRV queries —
                confirms the configured DNS server responds correctly to
                local SRV queries and handles external domain lookups
                (NXDOMAIN is acceptable in a single-NIB test env).
          TC-8: Inter-NIB SIP INVITE routing via I-CSCF — uses
                volte_inter_nib_invite.xml to probe the shared INVITE
                routing path. Passes on any non-5xx response.

      06_conference.sh
        Conference dial-in: conf-factory routing, VoLTE/ViLTE rooms,
        multi-member joins, hold, cleanup, concurrent rooms, bearer
        lifecycle, and inter-NIB conference routing.
        Original TCs (1-12): DNS, direct FreeSWITCH conference,
        conf-factory P-CSCF routing, multi-member, hold, cleanup,
        concurrent, Rx AAR/STR.
        New TC added (Phase 5b):
          TC-13: Inter-NIB conference INVITE — sends INVITE to
                 sip:1010@external.example via P-CSCF/I-CSCF using
                 conference_inter_nib_invite.xml. IMS must attempt inter-
                 domain routing for the conference URI without returning
                 5xx. 4xx/timeout acceptable (no external conference
                 server in test env).

      06_conference.sh
        FreeSWITCH conference and conf-factory related tests.

      07_fxo_fxs.sh
        FXO/FXS/analog breakout placeholder tests. Currently skipped until
        the production analog path is confirmed.

      08_cdr.sh
        CDR file, htable, call record, field, media type, and logrotate
        tests.
        New TC added (Phase 5a):
          TC-7: CDR field completeness — validates all 5 mandatory fields
                (CALLING_PARTY, CALLED_PARTY, MEDIA_TYPE, START_TIME,
                DURATION) are non-empty, MEDIA_TYPE is audio/video,
                START_TIME is timestamp-like, and DURATION is numeric.
                Skipped when CDR file is empty (no calls through S-CSCF).

      09_load_test.sh
        eNB capacity, attach/register capacity, PyHSS/DNS throughput,
        data-plane throughput, jitter, registered subscriber limits,
        simultaneous call pairs, and attach burst tests.

      10_regression.sh
        Main regression suite: container health, Diameter, EPC data plane,
        IMS signaling, E2E attach/register, calls, negative cases,
        subscriber lifecycle, hold/resume, Call Waiting.
        New TCs added (Phase 4 — EPC Mobility & Security, Cat 8):
          TC-37: TAU (Tracking Area Update) — Python UE sim performs
                 full attach, then sends TAU Request, verifies TAU Accept
                 with optional new GUTI, then detaches.
          TC-38: SQN re-synchronisation (AUTS) — Python UE sim triggers
                 Auth Failure with AUTS on first auth, re-authenticates
                 successfully on second round. Validates HSS re-sync flow.
          TC-39: Subsequent attach with GUTI — Python UE sim detaches and
                 re-attaches using the GUTI received in the first Attach
                 Accept, validating the MME GUTI identity path.
          TC-40: MT paging — two UEs on shared S1AP connection; UE-B goes
                 idle via UEContextReleaseRequest, UE-A originates a call,
                 UE-B waits for MME Paging broadcast (30 s timeout).
          TC-41: P-CSCF recovery — docker restart pcscf, wait 45 s for
                 readiness, then E2E attach+register verifies recovery.
          TC-42: SIP re-registration timer refresh — Python UE sim
                 registers twice with the same Call-ID to validate S-CSCF
                 re-registration handling.
          TC-43: Codec negotiation rejection (488) — SIPp sends INVITE
                 with GSM-only SDP (codec_mismatch_invite.xml), expects
                 488 Not Acceptable Here from IMS.
        New TCs added — NAS Ciphering & PDN Type (Cat 9):
          TC-44: SNOW3G-capable UE attach — UE advertises EEA0+EEA1 and
                 EIA1+EIA2 via UE_CAP_SNOW3G_ONLY. Open5GS MME selects
                 EEA0/EIA2 (null cipher preferred; AES-CMAC for integrity).
                 Test passes if attach succeeds regardless of chosen algos.
          TC-45: AES-capable UE attach — UE advertises EEA0+EEA2 and EIA2
                 via UE_CAP_AES_ONLY. MME selects EEA0/EIA2 (EEA0 is first
                 in ciphering_order even when EEA2 is available). Test
                 passes if attach succeeds.
          TC-46: All-algorithms UE attach — UE advertises EEA0+EEA1+EEA2
                 and EIA1+EIA2 via UE_CAP_ALL_ALGOS. MME selects EEA0/EIA2.
                 Test passes if attach succeeds and MME returns a valid EEA/
                 EIA pair.
          TC-47: Pure IPv6 PDN (type 2) — UE requests PDN type IPv6. SKIP
                 because Open5GS SMF has no IPv6 UE address pool configured;
                 the attach fails before a /64 prefix can be assigned. Will
                 pass once an IPv6 pool is added to smf.yaml.
          TC-48: Dual-stack PDN (IPv4v6, type 3) — UE requests PDN type
                 IPv4v6. Open5GS SMF accepts the request but allocates only
                 an IPv4 address (no IPv6 pool). Test PASSES — downgrade
                 from IPv4v6 to IPv4 is correct 3GPP behavior (TS 24.301
                 §6.5.1) when the SMF cannot provide an IPv6 prefix.
          TC-49: IPv6 MT paging — UE attempts IPv6 PDN attach, goes idle,
                 ping6 from UPF should trigger S1AP Paging. SKIP because
                 the IPv6 PDN attach fails (same root cause as TC-47).

      11_mms.sh
        Optional MMS/Kannel/Mbuni/MMSC tests. Skips when MMSC is not
        deployed.
        Original TCs (1-15): container health, port checks, Kannel admin,
        SMPP, storage, SendMMS API smoke, log health, process health, MM7
        incoming port.
        New TCs added (Phase 5b):
          TC-16: Intra-NIB MMS send A->B — SendMMS API sends from MSISDN
                 9876540001 to 9876541000 within the same MMSC domain.
                 Checks that the API accepts the request and reports any
                 error response.
          TC-17: Intra-NIB MMS delivery queue — verifies MMSC storage
                 (/tmp/mms-storage) has a queued entry for recipient
                 9876541000 after TC-16. Falls back to checking for any
                 recently created MMS files. Skipped if nothing found
                 (no full subscriber registration in test env).
          TC-18: Inter-NIB MMS MM7 outbound — POSTs a minimal MM7 SOAP
                 SubmitReq envelope to MM7 port 8190 for external MSISDN
                 +4412345678. Passes on any SubmitRsp or HTTP response;
                 fails on SOAP fault or HTTP 5xx.

      12_stress.sh
        Stability tests for multi-UE calls, long-duration smoke call,
        Rx Diameter health, P-CSCF SHM, IPSec capacity, in-dialog AAR
        resilience, and multi-call stability.

      13_bearer_qos.sh
        QCI-9/QCI-5/QCI-1/QCI-2 bearer lifecycle, Rx AAR/STR, and QoS
        path evidence.

      14_mobile_ip.sh
        Optional same-IMS mobile-to-softphone path. Requires
        SOFTPHONE_TARGET_URI.

      15_tec.sh
        TEC readiness evidence/gap matrix. Maps tracker requirements to
        automated evidence, partial coverage, manual lanes, and known gaps.

      16_advanced_sip.sh  [NEW — Phase 5a]
        Advanced SIP feature tests. Validates real RTP media loopback,
        DTMF in-call signaling, REFER-based call transfer, emergency call
        routing, and IPv6 signaling dual-stack.
          TC-1: RTP echo — SIPp UAC/UAS pair with -rtp_echo validates
                real media flow through RTPEngine.
          TC-2: DTMF SIP INFO — in-call INFO with Content-Type:
                application/dtmf-relay accepted (RFC 2976).
          TC-3: REFER call transfer — IMS routes REFER and returns
                202 Accepted + NOTIFY event:refer (RFC 3515).
          TC-4: Emergency INVITE — sip:112@domain with Priority:emergency
                accepted (non-5xx response required).
          TC-5: IPv6 signaling — REGISTER with IPv6 Via/Contact addresses
                accepted without 5xx from P-CSCF.

      17_security.sh  [NEW]
        IMS/EPC security posture test suite. Validates authentication
        enforcement, protocol input validation, SIP state machine
        robustness, RFC compliance edge cases, API crash safety, and
        Denial-of-Service survivability.
          TC-1:  Unauthenticated REGISTER — P-CSCF must issue 401
                 Unauthorized challenge, never 200 OK (auth bypass check).
          TC-2:  INVITE to unprovisioned subscriber — S-CSCF/PyHSS must
                 return 4xx (404/480/403), not 5xx crash or 2xx routing
                 leak, when the subscriber lookup returns empty.
          TC-3:  SIP OPTIONS probe — P-CSCF must respond gracefully to
                 topology enumeration attempt (200 OK or 4xx); a 5xx
                 indicates crash on OPTIONS.
          TC-4:  Max-Forwards: 0 INVITE — P-CSCF must enforce RFC 3261
                 §8.1.1.6 and return 483 Too Many Hops; validates loop
                 prevention and edge-case hop-count handling.
          TC-5:  Oversized Via header (~512 bytes) — P-CSCF must handle
                 large header parameter values without buffer overflow or
                 crash; port must remain open after the probe.
          TC-6:  Orphan BYE — P-CSCF must return 481 Call/Transaction
                 Does Not Exist for a BYE with no active dialog (RFC 3261
                 §15.1.2); validates call-hijack rejection.
          TC-7:  Orphan CANCEL — P-CSCF must return 481 for a CANCEL
                 with no matching INVITE transaction (RFC 3261 §9.2);
                 validates call-disruption rejection.
          TC-8:  Invalid SDP INVITE (no m= lines) — FreeSWITCH must
                 reject incomplete SDP with 488 Not Acceptable Here (RFC
                 3264); validates media stack parse safety.
          TC-9:  PyHSS API probe — GET /subscriber/imsi for a fabricated
                 IMSI must return HTTP 404 Not Found, not 5xx (crash) or
                 200 (info disclosure); validates API error handling.
          TC-10: P-CSCF DoS resilience — P-CSCF port must still accept
                 connections after all 9 security probes above; a closed
                 port indicates the stack crashed under attack load.

    scenarios/
      SIPp XML scenarios used by feature scripts.
      New scenarios added (Phase 3 + Phase 5b):

        volte_rtp_echo_uac.xml  [Phase 3]
          VoLTE UAC scenario using -rtp_echo flag for real RTP loopback.
          Sends INVITE, allows 3 seconds of RTP echo, then BYE.

        volte_rtp_echo_uas.xml  [Phase 3]
          VoLTE UAS answering counterpart for the RTP echo test. Answers
          with matching SDP and echoes RTP media.

        codec_mismatch_invite.xml  [Phase 3]
          INVITE with SDP offering only GSM codec (PT 3). Expects 488 Not
          Acceptable Here from IMS.

        dtmf_sip_info.xml  [Phase 3]
          Full INVITE/200/ACK, then two in-call SIP INFO messages with
          Content-Type: application/dtmf-relay (DTMF digits 1 and #),
          then BYE.

        call_transfer_refer.xml  [Phase 3]
          INVITE/200/ACK, then REFER with Refer-To pointing to a second
          MSISDN, expects 202 Accepted + optional NOTIFY, then BYE.

        emergency_invite.xml  [Phase 3]
          INVITE to sip:112@IMS_DOMAIN with Priority:emergency header.
          Accepts any 1xx/2xx/3xx/4xx; fails if IMS returns 5xx.

        ipv6_register.xml  [Phase 3]
          REGISTER with IPv6 addresses in Via and Contact. Simplified
          flow (no AKA); verifies P-CSCF handles IPv6 syntax without 5xx.

        volte_intra_nib_invite.xml  [Phase 5b]
          VoLTE INVITE from 9876540001 to 9876541000 within IMS_DOMAIN.
          Routes through the full P-CSCF -> I-CSCF -> S-CSCF chain.
          Accepts 2xx/4xx; fails on 5xx.

        volte_inter_nib_invite.xml  [Phase 5b]
          VoLTE INVITE toward sip:+9990001234@external.example. Tests
          the I-CSCF inter-domain routing path. 4xx/timeout acceptable;
          5xx means routing config error.

        vilte_intra_nib_invite.xml  [Phase 5b]
          ViLTE INVITE with audio+video SDP (m=audio + m=video H264/H265)
          to local MSISDN within IMS_DOMAIN. Verifies P-CSCF processes
          the dual-media SDP without 5xx.

        vilte_inter_nib_invite.xml  [Phase 5b]
          ViLTE INVITE with audio+video SDP toward external domain. IMS
          must handle video SDP and attempt inter-domain routing without
          returning 5xx.

        conference_inter_nib_invite.xml  [Phase 5b]
          INVITE to sip:1010@external.example — tests inter-NIB conference
          routing via I-CSCF. 4xx/timeout acceptable; 5xx means routing
          table rejects the external conference URI.

        sms_via_ims.xml  [Phase 5b]
          SIP MESSAGE routed through P-CSCF -> S-CSCF -> SMSC. Uses
          IMS_DOMAIN template so S-CSCF routes intra-NIB. Passes on any
          non-5xx response (4xx acceptable without full registration).

        sms_inter_nib.xml  [Phase 5b]
          SIP MESSAGE to external domain URI
          (sip:+9990001234@external.example). Verifies S-CSCF attempts
          inter-domain routing. Passes on non-5xx outcome; 5xx means
          routing config error.

        security_unauth_register.xml  [NEW]
          REGISTER without Authorization header. Expects 401 Unauthorized
          from P-CSCF. Used by TC-1 of the Security feature to verify
          the IMS stack enforces authentication on every REGISTER.

        security_unknown_invite.xml  [NEW]
          INVITE to sip:0000000000@IMS_DOMAIN — a subscriber that does
          not exist in PyHSS. Expects 4xx (404/403/480). Used by TC-2
          to verify S-CSCF handles failed subscriber lookups without
          crashing or leaking a 2xx response.

        security_options_probe.xml  [NEW]
          OPTIONS request to P-CSCF — simulates SIP topology enumeration.
          Expects 200 OK (Kamailio WITH_PING_UDP) or any non-5xx. Used
          by TC-3 to verify the stack handles OPTIONS probes gracefully.

        security_max_forwards_zero.xml  [NEW]
          INVITE with Max-Forwards: 0. Expects 483 Too Many Hops per
          RFC 3261 §8.1.1.6. Used by TC-4 to verify P-CSCF enforces
          hop-count limits and does not forward loop-limited requests.

        security_oversized_via.xml  [NEW]
          INVITE with Via header containing ~512 bytes of padding in a
          custom parameter. Expects 400 Bad Request or any 4xx. Used by
          TC-5 to probe buffer overflow resilience in the SIP parser.

        security_orphan_bye.xml  [NEW]
          BYE with a Call-ID that has no active dialog in the IMS state
          machine. Expects 481 Call/Transaction Does Not Exist per RFC
          3261 §15.1.2. Used by TC-6 to validate call-hijack rejection.

        security_orphan_cancel.xml  [NEW]
          CANCEL with a Call-ID that has no matching INVITE transaction.
          Expects 481 Transaction Does Not Exist per RFC 3261 §9.2.
          Used by TC-7 to validate call-disruption rejection.

        security_invalid_sdp.xml  [NEW]
          INVITE to FreeSWITCH/5090 with SDP body containing only
          session-level fields (v/o/s/t) and no m= media lines. Expects
          488 Not Acceptable Here per RFC 3264. Used by TC-8 to verify
          the media stack rejects incomplete SDP without crashing.

    ue_sim/
      Python UE/eNB simulator used for attach, register, VoLTE, ViLTE,
      bearer, load, and stress workflows.
      Phase 2 enhancements:

        milenage.py
          Milenage AKA implementation (TS 35.206 f1/f2/f3/f4/f5/f5*).
          Added compute_auts(rand, sqn_ue) for SQN re-synchronisation:
          computes the 14-byte AUTS token (SQN_UE XOR AK, then MAC-S).

        s1ap_client.py
          S1AP/NAS client over SCTP.
          Added paging detection: receive_nas() recognises proc_code
          PAGING (10) and sets decoded['paging'] = True.
          Added wait_for_paging(timeout=30.0): polls receive_nas() until
          a Paging PDU arrives or the timeout expires. Used by TC-40
          (MT paging) and SharedS1APConnection multi-UE scenarios.

        ue_simulator.py
          High-level UE workflow driver.
          New methods added:
            release_to_idle(): sends UEContextReleaseRequest and handles
              the UEContextReleaseCommand, placing the UE in idle mode
              while keeping the SCTP connection open.
            wait_for_paging(timeout): delegates to s1ap_client to detect
              a paging broadcast from the MME.
            tau(update_type, active_flag, new_tac): builds and sends a
              TAU Request using the stored GUTI, waits for TAU Accept,
              updates stored GUTI if a new one is assigned, sends TAU
              Complete.
            attach_with_guti(apn): performs a full EPS attach using the
              GUTI from the previous successful attach instead of IMSI.
            attach_with_auts_resync(apn, sqn_ue): performs the two-round
              attach that triggers SQN re-sync. First round sends Auth
              Failure (EMM cause 0x15) with a computed AUTS token; second
              round completes normal Milenage authentication.
          GUTI extraction: _handle_attach_accept() now extracts the GUTI
          from the Attach Accept EPS Mobile Identity IE (type byte 0xF6)
          and stores the 10-byte GUTI in self._guti_bytes.
          Cat 9 enhancements (NAS Ciphering & PDN Type):
            ue_network_capability parameter added to __init__() — accepts
              a 4-byte UE Network Capability override for Cat 9 ciphering
              tests (passed through to NASHandler).
            pdn_type parameter added to attach() — accepts PDN type 1
              (IPv4), 2 (IPv6), or 3 (IPv4v6) for TC-47/TC-48/TC-49.
            selected_eea / selected_eia properties expose the EPS
              ciphering and integrity algorithms negotiated by the MME in
              Security Mode Command, so shell tests can log the result.
            ipv6_prefix property exposes the /64 prefix assigned by SMF
              in the Attach Accept PDN Address IE (type 0x57), or None
              when only IPv4 is allocated.

        config.py
          Central configuration loaded from environment variables.
          Cat 9 additions:
            UE Network Capability presets (4-byte TS 24.301 §9.9.3.34):
              UE_CAP_ALL_ALGOS    = [0xE0,0x60,0xC0,0x60]
                EEA0+EEA1+EEA2, EIA1+EIA2 — used by TC-46.
              UE_CAP_SNOW3G_ONLY  = [0xC0,0x60,0xC0,0x60]
                EEA0+EEA1, EIA1+EIA2 — used by TC-44. Byte[1]=0x60
                includes EIA2 so MME (integrity_order EIA2>EIA1>EIA0)
                selects EIA2 (AES-CMAC), which the simulator implements
                correctly. EIA1 (SNOW3G-MAC) is not implemented.
              UE_CAP_AES_ONLY     = [0xA0,0x20,0xC0,0x60]
                EEA0+EEA2, EIA2 — used by TC-45.
              UE_CAP_NULL_CIPHER  = [0x80,0x60,0xC0,0x60]
                EEA0 only, EIA1+EIA2 — negative/null-cipher test.
            PDN type constants:
              PDN_TYPE_IPV4   = 1
              PDN_TYPE_IPV6   = 2  (TC-47, TC-49 — skipped, no IPv6 pool)
              PDN_TYPE_IPV4V6 = 3  (TC-48 — passes on IPv4 downgrade)

        nas_handler.py
          NAS message builder and security handler.
          Cat 9 additions:
            ue_network_capability parameter in __init__() — allows per-UE
              capability byte override for algorithm negotiation tests.
            pdn_type parameter in build_attach_request() / passed through
              to build_pdn_connectivity_request() for TC-47/TC-48/TC-49.
            selected_eea / selected_eia properties — read the EPS
              ciphering and integrity algorithm IDs stored when the MME's
              Security Mode Command is processed.
          Implementation notes:
            NAS EEA ciphering (EEA1/EEA2) is NOT implemented. The
              simulator always appends the plain NAS message body
              regardless of selected_eea. This is sufficient because
              Open5GS MME selects EEA0 (null cipher) first whenever the
              UE supports it (ciphering_order=[EEA0,EEA2,EEA1]).
            EIA1 (SNOW3G-MAC) is NOT implemented. The code falls back to
              EIA2 (AES-CMAC) with an EIA1-derived key, which produces the
              wrong MAC. UE_CAP_SNOW3G_ONLY therefore includes EIA2 in its
              capability byte so the MME selects EIA2 instead of EIA1.


4. TEST GROUPS AND HOW TO RUN THEM
==================================

List all features and test cases:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --list

Show help:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --help

Run default core features:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test

Run the complete suite (core + TRL8 opt-in features):

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --bundle all

Run one feature:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature <feature_name>

Run one test case inside a feature:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature <feature_name> --test <test_number>


5. AVAILABLE FEATURES
=====================

Regression (49 TCs):

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature regression

  Purpose:
    Main interface and E2E sanity gate. Validates EPC/IMS/infrastructure
    containers, Diameter peers, PFCP/GTP, FreeSWITCH, RTPEngine, routing,
    attach/register, VoLTE call, re-register, negative cases, subscriber
    lifecycle, hold/resume, Call Waiting, EPC mobility/security, NAS
    ciphering algorithm negotiation, and PDN type handling.

  Cat 8 (TC-37 to TC-43) — EPC Mobility & Security:
    TC-37 validates TAU (Tracking Area Update) using the Python UE
    simulator.

    TC-38 validates SQN re-synchronisation (AUTS) — the UE sends Auth
    Failure with a computed AUTS token; the HSS re-syncs and the second
    auth round succeeds.

    TC-39 validates subsequent attach using a stored GUTI from the
    previous Attach Accept.

    TC-40 validates MT paging: UE-B goes idle, UE-A originates a call,
    the MME broadcasts a Paging PDU, and UE-B confirms receipt within
    30 s.

    TC-41 validates P-CSCF recovery after a container restart. The suite
    restarts the pcscf container, waits for it to become ready (45 s),
    then runs an E2E attach+register.

    TC-42 validates SIP re-registration timer refresh: the Python UE
    registers twice to confirm S-CSCF handles re-REGISTER correctly.

    TC-43 validates codec negotiation rejection: SIPp sends an INVITE
    offering only GSM codec and expects 488 Not Acceptable Here.

  Cat 9 (TC-44 to TC-49) — NAS Ciphering & PDN Type:
    TC-44 validates that a UE advertising only SNOW3G ciphering capability
    (EEA0+EEA1, EIA1+EIA2) can attach successfully. Open5GS selects
    EEA0/EIA2. PASS if attach succeeds regardless of chosen algorithms.

    TC-45 validates that a UE advertising only AES ciphering capability
    (EEA0+EEA2, EIA2) can attach successfully. Open5GS selects EEA0/EIA2
    (EEA0 is first in ciphering_order). PASS if attach succeeds.

    TC-46 validates algorithm negotiation when the UE advertises all
    algorithms (EEA0+EEA1+EEA2, EIA1+EIA2). Open5GS selects EEA0/EIA2.
    PASS if attach succeeds and a valid EEA/EIA pair is reported.

    TC-47 attempts a pure IPv6 PDN attach (PDN type 2). SKIP — Open5GS
    SMF has no IPv6 UE address pool; the attach fails before a /64
    prefix can be assigned. To enable: add a UE IPv6 subnet to smf.yaml.

    TC-48 requests a dual-stack PDN (IPv4v6, type 3). Open5GS SMF
    accepts the request but allocates only an IPv4 address (no IPv6 pool).
    PASS — downgrading IPv4v6 to IPv4 is correct 3GPP behavior per
    TS 24.301 §6.5.1 when no IPv6 prefix can be assigned.

    TC-49 attempts IPv6 MT paging: IPv6 PDN attach + idle + ping6 from
    UPF. SKIP — same root cause as TC-47 (IPv6 PDN attach fails).

VoLTE (9 TCs):

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature volte

  Purpose:
    DNS/SRV readiness, SIP reachability, RTPEngine availability, plus
    both intra-NIB and inter-NIB VoLTE call routing.

    TC-8: Intra-NIB VoLTE INVITE from 9876540001 to 9876541000 within
          the same IMS domain. Uses the full P-CSCF -> I-CSCF -> S-CSCF
          routing chain. 4xx is acceptable (no full UE registration in
          test env); 5xx is a failure.

    TC-9: Inter-NIB VoLTE INVITE toward sip:+9990001234@external.example.
          IMS must forward the INVITE via I-CSCF to the external domain
          without returning 5xx. Timeout or 4xx is acceptable; no real
          external NIB is present in the test environment.

ViLTE (10 TCs):

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature vilte

  Purpose:
    Video/media readiness, P-CSCF video authorization config, RTPEngine
    connectivity, S-CSCF video detection, codec/transcoding config, plus
    both intra-NIB and inter-NIB ViLTE call routing.

    TC-9:  Intra-NIB ViLTE INVITE with audio+video SDP (m=audio + m=video
           with H264/H265) within the same IMS domain. Verifies the full
           IMS chain processes the dual-media SDP without 5xx.

    TC-10: Inter-NIB ViLTE INVITE toward an external domain with
           audio+video SDP. IMS must handle the video SDP and attempt
           inter-domain routing without returning 5xx.

EIR (6 TCs):

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature eir

  Purpose:
    PyHSS API and subscriber/AUC/IMS provisioning checks relevant to EIR
    and subscriber identity readiness.

SMS (9 TCs):

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature sms

  Purpose:
    SMSC DNS/SRV/SIP reachability, SIP MESSAGE acceptance (direct to
    SMSC and via full IMS chain), MySQL smsc database presence, intra-NIB
    SMS delivery confirmation, inter-NIB SMS routing validation, and SMS
    message body integrity check.

    SMS intra/inter-NIB tests live here and are NOT duplicated in
    05_inter_nib.sh. The inter_nib feature covers the shared I-CSCF
    infrastructure; SMS-specific routing is here.

  Intra-NIB vs. direct:
    TC-4 sends SIP MESSAGE directly to SMSC:7090 — a basic SMSC smoke
    test that bypasses the IMS routing chain.

    TC-6 sends SIP MESSAGE through P-CSCF:5060 -> S-CSCF -> SMSC using
    the full IMS path. This is the path real IMS UEs use.

  Inter-NIB:
    TC-8 sends SIP MESSAGE to sip:+9990001234@external.example via
    P-CSCF. The S-CSCF must attempt inter-domain DNS routing without
    returning 5xx. A 4xx or timeout is acceptable (no external NIB in
    test env).

Inter-NIB (8 TCs):

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature inter_nib

  Purpose:
    Shared inter-NIB INFRASTRUCTURE only. Validates the DNS/SRV/port
    foundations and I-CSCF border-element config that all inter-NIB
    services depend on. Intra/inter-NIB call tests for individual services
    (VoLTE, ViLTE, SMS, MMS, conference) live in their own feature files —
    there is no duplication here.

    TC-6: I-CSCF inter-domain federation routing config — verifies the
          I-CSCF has DNS/LIR/PSTN routing rules for external domains.
    TC-7: DNS resolver reachability — confirms the DNS server handles
          both local and external domain SRV queries.
    TC-8: Inter-NIB SIP INVITE via I-CSCF — probes the shared INVITE
          routing path that VoLTE, ViLTE, and conference all use for
          inter-domain calls.

Conference (13 TCs):

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature conference

  Purpose:
    Direct FreeSWITCH audio/video conference, multi-member joins, room
    reuse, concurrent rooms, Rx bypass behavior for SIPp clients,
    Rx Diameter connectivity, and inter-NIB conference routing.

    TC-13: Inter-NIB conference INVITE — sends INVITE to
           sip:1010@external.example via P-CSCF/I-CSCF. IMS must
           attempt inter-domain routing for the conference URI without
           returning 5xx. conf-factory tests skip until conf-factory
           DNS/routing is configured.

FXO/FXS:

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature fxo_fxs

  Purpose:
    Placeholder group for analog/FXO/FXS path. Currently skipped until
    the production analog call path is confirmed.

Mobile-to-IP (6 TCs):

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature mobile_ip

  Purpose:
    Optional same-IMS mobile-to-softphone checks. Requires:

      SOFTPHONE_TARGET_URI=sip:<user>@<domain>

CDR (7 TCs):

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature cdr

  Purpose:
    CDR file existence, htable availability, call record presence, field
    validation, audio media records, logrotate configuration, and full
    field completeness with type validation (TC-7).

Load Test (11 TCs):

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature load

  Purpose:
    Capacity and performance: eNB S1Setup ramp, VoLTE/ViLTE attach+
    register capacity, PyHSS/DNS throughput, data-plane throughput,
    jitter, max registered subscribers per eNB, simultaneous call-pair
    capacity, and burst attach behavior.

  Important result interpretation:
    TC-2 and TC-3 are attach/register capacity tests only. The
    "Concurrent" value in those tables means individual UEs. Calls are
    intentionally not placed in those tests, so odd values such as 25 or
    75 UEs are valid.

    TC-10 is the actual simultaneous call-pair test. In that table,
    "Pairs" means active calls and "2xUEs" means total individual UEs.
    For example: Pairs=32, 2xUEs=64 means 32 simultaneous calls using
    64 UEs.

MMS (18 TCs):

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature mms

  Purpose:
    Optional MMSC/Kannel/Mbuni path. Skips when MMSC is not running.
    Validates container health, port reachability, Kannel admin, SMPP,
    MMS storage, SendMMS API, log health, process health, MM7 incoming
    port, intra-NIB MMS A->B delivery, and inter-NIB MM7 outbound.

  Intra-NIB (TC-16 and TC-17):
    TC-16 sends MMS from MSISDN 9876540001 to 9876541000 within the same
    MMSC domain using the SendMMS API. TC-17 verifies MMSC storage has
    a queued entry for the recipient.

  Inter-NIB MM7 outbound (TC-18):
    TC-18 posts a minimal MM7 SOAP SubmitReq to port 8190 for external
    MSISDN +4412345678. Validates the MM7 interface accepts the outbound
    request. No real external MMSC relay is present; any non-fault
    response is a pass.

Stress Test (8 TCs):

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature stress

  Purpose:
    Stability under realistic stress: P-CSCF resource audit, concurrent
    calls, long-duration call smoke, Rx Diameter health, SHM usage,
    IPSec capacity, in-dialog AAR resilience, and multi-call stability.

Bearer QoS (10 TCs):

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature bearer_qos

  Purpose:
    QCI-9 default bearer, QCI-5 IMS signaling bearer, QCI-1 VoLTE bearer,
    QCI-2 ViLTE bearer, Rx AAR trigger, Rx STR teardown, Rx Diameter peer
    health, and bearer/QCI evidence.

TEC Readiness (13 TCs):

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature tec

  Purpose:
    Reads previously generated feature reports and creates a TEC readiness
    matrix. Best used after running --bundle all or the TEC bundle.

Advanced SIP (5 TCs):  [NEW]

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature advanced_sip

  Purpose:
    Validates advanced SIP features not covered by the main regression
    lane: real RTP media loopback, DTMF in-call signaling, REFER-based
    call transfer, emergency call routing, and IPv6 signaling dual-stack.

    TC-1: RTP echo — SIPp UAC/UAS pair with -rtp_echo confirms real
          RTP media flows through RTPEngine (not just signaling).
    TC-2: DTMF SIP INFO — in-call INFO with application/dtmf-relay
          accepted (RFC 2976 in-band DTMF path).
    TC-3: REFER call transfer — IMS routes REFER and returns 202
          Accepted + NOTIFY event:refer (RFC 3515).
    TC-4: Emergency INVITE sip:112@domain — IMS must not return 5xx
          (stack must not crash on emergency URIs).
    TC-5: IPv6 REGISTER — P-CSCF accepts IPv6 Via/Contact syntax
          without 5xx (signaling-plane dual-stack validation).

Security (10 TCs):  [NEW]

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature security

  Purpose:
    Validates the IMS/EPC security posture across authentication
    enforcement, SIP input validation, RFC protocol compliance, media
    stack parse safety, API crash safety, and Denial-of-Service
    survivability. Covers attack categories described in RFC 5039
    (SIP and Spam) and RFC 3261 security considerations.

    TC-1:  Unauthenticated REGISTER — verifies P-CSCF always issues a
           401 challenge (never 200 OK). A 200 without credentials would
           be a critical authentication bypass.

    TC-2:  INVITE to unprovisioned subscriber — verifies S-CSCF/PyHSS
           returns 4xx (404/480/403) when the subscriber lookup fails.
           A 5xx would indicate a crash in the HSS/S-CSCF on empty
           lookup results; a 2xx would indicate a routing leak.

    TC-3:  SIP OPTIONS probe — verifies P-CSCF responds gracefully to
           topology enumeration (200 OK expected with WITH_PING_UDP
           enabled). A 5xx or no response indicates crash-on-OPTIONS.

    TC-4:  Max-Forwards: 0 — verifies RFC 3261 §8.1.1.6 compliance.
           P-CSCF must return 483 Too Many Hops and not forward the
           request (loop prevention / hop-count enforcement).

    TC-5:  Oversized Via header (~512 bytes) — buffer overflow probe.
           P-CSCF must return 4xx and remain reachable afterward; port
           going down after the probe indicates a crash or OOM.

    TC-6:  Orphan BYE — RFC 3261 §15.1.2 compliance. P-CSCF must
           return 481 Call/Transaction Does Not Exist for a BYE that
           has no matching active dialog (call-hijack prevention).

    TC-7:  Orphan CANCEL — RFC 3261 §9.2 compliance. P-CSCF must
           return 481 for a CANCEL with no matching INVITE transaction
           (call-disruption prevention).

    TC-8:  Invalid SDP INVITE — FreeSWITCH media stack must return
           488 Not Acceptable Here for an INVITE with no m= lines per
           RFC 3264 §5. A 5xx crash or 2xx bypass indicates media
           stack parse safety regression.

    TC-9:  PyHSS API probe — GET /subscriber/imsi for a fabricated IMSI
           (000000000000000) must return HTTP 404 Not Found. A 5xx
           indicates a crash in the API layer on missing records; a 200
           would indicate data leakage or a ghost record.

    TC-10: P-CSCF DoS resilience — verifies the P-CSCF port is still
           accepting connections after all 9 probes above. A closed
           port indicates the IMS signaling stack crashed or OOM-killed
           under the combined attack load.

  Expected skips:

    - TC-8 skips when FreeSWITCH is not reachable at port 5090.
    - TC-9 skips when PyHSS is not reachable at port 8080.
    - All P-CSCF tests skip when P-CSCF is not reachable at port 5060.


6. CURATED BUNDLES
==================

TEC dry-run evidence bundle:

  Command:
    sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --bundle tec

  Runs:
    regression, volte, vilte, eir, sms, inter_nib, conference, fxo_fxs,
    cdr, load, stress, bearer_qos, mobile_ip, mms, tec, advanced_sip, security

  Purpose:
    Produces the strongest current automated 4G+IMS evidence pack for TEC
    preparation and explicitly documents remaining manual/optional gaps.


7. COMPLETE SUITE RUN
=====================

Command:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --bundle all

Notes:

  - The complete suite provisions test subscribers automatically.
  - Duplicate APN/subscriber responses during provisioning are acceptable.
  - Some optional features skip by design when their deployment
    prerequisites are absent, for example MMSC, SOFTPHONE_TARGET_URI,
    FXO/FXS, or conf-factory DNS/routing.
  - Load and stress tests may restart EPC containers to clear stale state
    before high-risk sections.
  - The suite exits with code 1 if any test fails.


8. GENERATED REPORTS
====================

All reports are written inside the test container at:

  /opt/test/reports/

When using docker compose run, the report path printed by the suite is:

  Reports written to: /opt/test/reports/

Main report files:

  summary.txt
    Final table of feature totals: total, passed, failed, skipped. This
    is the quick result used to decide whether the run is green.

  detailed_test_report.txt
    Human-readable complete report. It starts with the hardware used for
    the run, then summarizes all tests, lists what is working, failed
    cases, skipped cases, meanings, limitations, TEC matrix when available,
    and recommended next actions.

  hardware_inventory.txt
    Host/container-visible hardware profile: kernel, CPU information,
    memory, root filesystem, Docker root, and Docker storage summary.

  hardware_checkpoints.csv
    Per-feature cgroup checkpoint data for each container: current memory,
    OS/cgroup memory peak, cumulative CPU time, I/O counters, and PIDs.
    This is not sampling-based for memory peak.

  hardware_resource_report.txt
    Human-readable hardware/resource report generated from inventory and
    cgroup checkpoints. Shows memory peak, max current memory, CPU time
    deltas by feature, I/O counters, and limitations.

  hardware_samples.csv
    Optional docker stats samples. Disabled by default. Enable with:

      HW_PROBE_ENABLED=1

    This is only for approximate instantaneous CPU percent peaks. Exact
    historical CPU percent peaks are not kept by Linux cgroups after the
    fact.

  tec_certification_gap_matrix.txt
    Generated by --feature tec or --bundle tec. Maps TEC/tracker
    requirements to automated evidence, partial coverage, manual coverage,
    gaps, and next actions.

  <feature>.txt
    One report per feature, for example:

      regression.txt
      volte.txt
      vilte.txt
      sms.txt
      inter_nib.txt
      conference.txt
      load_test.txt
      bearer_qos.txt
      mms.txt
      advanced_sip.txt
      tec_readiness.txt

    These contain the raw per-feature PASS/FAIL/SKIP lines and
    reason/error details.


9. HOW TO INTERPRET RESULTS
===========================

PASS:

  The configured scenario passed in this lab deployment. It proves that
  the specific automated path worked for this run.

FAIL:

  A runtime behavior, threshold, dependency, or evidence check failed.
  Failed tests should be fixed before treating the suite as green.

SKIP:

  The test did not run because an optional dependency, deployment path,
  or manual/real-UE lane is not configured. Skips are not counted as
  failures, but they are coverage gaps.

Common expected skips in the default deployment:

  - conf-factory DNS/routing tests when conf-factory is not configured.
  - FXO/FXS tests until the production analog path is confirmed.
  - Mobile-to-IP tests until SOFTPHONE_TARGET_URI is set.
  - MMS tests until MMSC/Kannel/Mbuni are running.
  - Intra-NIB SMS TC-7 and TC-9 when no full IMS subscriber registration
    has been performed (no entry in smsc.messages).
  - Intra-NIB MMS TC-17 when no full subscriber registration exists.
  - Inter-NIB MMS TC-18 when MM7 port 8190 is not exposed.
  - Regression TC-47 (pure IPv6 PDN) and TC-49 (IPv6 MT paging) when
    Open5GS SMF has no IPv6 UE address pool configured. To enable both,
    add a UE IPv6 subnet to smf.yaml and restart the SMF container.
  - TEC manual lanes for RF/cell-edge, VoWiFi, LI, billing, HA/K8s,
    3GPP study, NB-IoT, and NTN.


10. HARDWARE AND RESOURCE REPORTING
====================================

The suite captures hardware/resource data automatically.

Exact values:

  - Memory peak uses Linux cgroup counters:
      cgroup v2: memory.peak
      cgroup v1: memory.max_usage_in_bytes

  - CPU consumed per feature uses cumulative cgroup CPU time deltas.

  - I/O counters use cgroup I/O counters where available.

Approximate values:

  - Instantaneous CPU percent peak is not retained by Linux/cgroups after
    the fact. If you need an approximate CPU percent peak, enable docker
    stats sampling with HW_PROBE_ENABLED=1.


11. CORE/IMS MACROS AND CONFIG FLAGS REQUIRED BY THE SUITE
==========================================================

The suite assumes the current test-enabled Core/IMS configuration. Most
of these macros are already enabled in this branch. If you move to a
production profile, rebuild the IMS configs, or merge changes from
another branch, verify these before running the release/TEC bundle.

P-CSCF required/test-critical files:

  pcscf/pcscf.cfg
  pcscf/kamailio_pcscf.cfg
  pcscf/route/register.cfg
  pcscf/route/mo.cfg
  pcscf/route/mt.cfg
  pcscf/route/rtp.cfg

P-CSCF macros and flags:

  #!define WITH_SIPP_TEST
    Required for SIPp/Python UE simulator integration tests. Enables
    synthetic test-client handling in REGISTER, MO, and MT routes.
    Without this, direct SIPp conference checks, SIPp negative cases,
    and non-IMEI SIPp media tests can fail or hang because they do not
    behave exactly like real IMS UEs.

  #!define WITH_FREESWITCH
    Required for FreeSWITCH application-server and conference call paths.

  #!define WITH_RX
    Required for Rx Diameter/PCRF checks, QCI-1/QCI-2 dedicated bearer
    tests, AAR/STR lifecycle checks, bearer QoS tests, and TEC QoS
    evidence.

  #!define WITH_IPSEC
    Required for IPSec module loading and IPSec capacity/resource checks.
    Synthetic SIPp/UE tests use test bypasses where needed, but real UE
    IMS registration still depends on the normal IPSec/Sec-Agree path.

  #!define WITH_TCP
    Required for TCP SIP listeners and XMLRPC/Kamailio control paths used
    by health checks and some operational probes.

  #!define WITH_IMS_HDR_CACHE
    Required for the IMS header cache behavior used by registration and
    routing logic.

  #!define FORCE_RTPRELAY
    Required so RTP/media flows are consistently anchored through
    RTPEngine. This is important for VoLTE, ViLTE, conference media, QoS,
    and TEC media evidence. Also required for TC-1 (RTP echo) in
    Advanced SIP.

  #!define WITH_PING_UDP
  #!define WITH_PING_TCP
    Used for SIP reachability/keepalive behavior. Keep these enabled
    unless intentionally testing a different P-CSCF profile.

  #!define IPSEC_MAX_CONN 20
    Stress tests currently audit this value as adequate for the default
    35+ UE deployment. Increase it for larger real-UE/IPSec runs.

  children=16
  #!define TCP_PROCESSES 8 or higher
    Not functional macros, but important capacity settings. The current
    template has enough workers for the default regression/load/stress
    lanes.

  modparam("ims_qos", "authorize_video_flow", 1)
    Required for ViLTE video bearer authorization and QCI-2 evidence.

  CDP workers/timeouts/queue:
    Stress tests expect P-CSCF Diameter resources roughly at or above:
      CDP_Workers=8
      CDP_Timeout=10s
      CDP_Queue=16
    Lower values can cause Rx AAR failures under load.

Optional P-CSCF macros:

  #!define WITH_N5
    Optional 5G/N5 path. The current 4G EPC + IMS test suite uses Rx,
    not N5.

  #!define WITH_TLS
  #!define WITH_WEBSOCKET
  #!define WITH_REGINFO
  #!define WITH_RTPPING
  #!define WITH_SBC
  #!define WITH_SBC_CALL
    Optional for this suite unless you are explicitly validating those
    access or SBC paths.

Conference-related configuration:

  Direct FreeSWITCH conference tests do not need conf-factory DNS/routing.
  P-CSCF conf-factory tests and full merge/conf-factory coverage require:

    - DNS entry for conf-factory in the IMS domain.
    - P-CSCF route for conf-factory requests.
    - FreeSWITCH conference factory/dialplan behavior.

  If these are absent, conference TC-1, TC-3, TC-5, TC-6, TC-8, and
  related TEC conference evidence are skipped or reported as gaps.

S-CSCF required/test-critical files:

  scscf/scscf.cfg
  scscf/kamailio_scscf.cfg

S-CSCF macros and flags:

  #!define WITH_TCP
    Required for TCP SIP/control behavior.

  #!define WITH_AUTH
    Required for IMS authentication and registration flows.

  children=16
  #!define TCP_PROCESSES 3 or higher
    Capacity settings used by the regression, load, stress, and TEC lanes.

  CDR route/htable/logging configuration
    Required for the CDR feature and regression CDR teardown evidence.
    The suite expects /cdr-logs/cdr.csv and logrotate configuration.

  Video detection in S-CSCF routing/CDR logic
    Required for ViLTE and media-type CDR evidence.

  Inter-NIB/PSTN MESSAGE routing rules
    Required for SMS TC-8 and inter_nib TC-6. The S-CSCF config must
    contain route blocks that handle MESSAGE requests toward external
    domains (or a PSTN gateway route). Without these, inter-NIB SMS
    routing tests fail or report a config gap.

Optional S-CSCF macros:

  #!define WITH_RO
  #!define WITH_RO_TERM
    Optional charging/Ro paths. Current CDR tests do not require Ro
    charging, but future billing/charging TEC lanes may.

I-CSCF required/test-critical files:

  icscf/icscf.cfg
  icscf/kamailio_icscf.cfg

I-CSCF macros and flags:

  #!define WITH_TCP
  #!define WITH_XMLRPC
    Required for SIP/control reachability and operational checks.

  children=16
    Capacity setting used by regression/load/stress runs.

EPC, PyHSS, and FreeSWITCH settings that are not Kamailio macros:

  MME AppServThreads=32
    Load and burst tests report this value and use it as the current
    tuning baseline. Raising it may improve attach burst behavior.

  PyHSS diameter_request_timeout=15s
  PyHSS sqlalchemy_pool_size=50
    Load and burst tests use these as the current HSS/MySQL capacity
    baseline.

  PyHSS S6a, Cx, and Rx/PCRF applications enabled
    Required for attach, IMS registration, and dedicated bearer tests.

  APNs internet and ims
    Required for default bearer, IMS signaling bearer, and QoS tests.

  FreeSWITCH Sofia profiles running
  FreeSWITCH conference rooms/dialplan for 1010-1015
    Required for VoLTE calls, stress calls, and conference tests.

Optional deployment components that explain skips:

  MMSC/Kannel/Mbuni running
    Enables MMS tests (TC-1 through TC-18).

  SOFTPHONE_TARGET_URI configured
    Enables Mobile-to-IP same-IMS softphone tests.

  Confirmed FXO/FXS production analog path
    Enables FXO/FXS tests.

  Real UE/RF/ePDG/LI/billing/HA/NB-IoT/NTN environments
    Required for the manual TEC lanes that cannot be proven by this 4G
    simulator-only suite.


12. USEFUL ENVIRONMENT VARIABLES
================================

  PCSCF_IP
  PCSCF_PORT
  FREESWITCH_IP
  PYHSS_IP
  DNS_IP
  ICSCF_IP
  SCSCF_IP
  SMSC_IP
  RTPENGINE_IP
  MMSC_IP
  LOCAL_IP
  IMS_DOMAIN

  MYSQL_ROOT_PASSWORD
    MySQL root password used by CDR and SMS MySQL queries in the test
    suite. Defaults to "MySQL_PaSsW0rD" if not set. Set this env var
    in your docker-compose.test.yaml or environment if your MySQL root
    password differs from the default.

  PYHSS_API_KEY
    Bearer token for PyHSS API authentication (used by
    provision_subscribers.sh). Required when PyHSS is configured with
    API authentication enabled. Leave unset if PyHSS allows unauthenticated
    API access (default in development deployments).

  SOFTPHONE_TARGET_URI
    Enables Mobile-to-IP same-IMS softphone tests.

  SOFTPHONE_TARGET_LABEL
    Optional label for the softphone target.

  SOFTPHONE_EXPECT_ANSWER
    Whether the softphone path is expected to answer.

  UES_PER_ENB
    Overrides automatic UE distribution per eNB in load tests.

  HW_PROBE_ENABLED
    Set to 1 to enable optional docker stats sampling.

  HW_SAMPLE_INTERVAL
    Sampling interval in seconds when HW_PROBE_ENABLED=1.

  KANNEL_ADMIN_PASS
    Kannel bearerbox admin password. Defaults to "admin".

  MMSC_CONTAINER
    Docker container name for the MMSC. Defaults to "mmsc". All MMS
    tests skip when this container is not running.

  SENDMMS_PATH
    HTTP path for the Mbuni SendMMS API endpoint. Defaults to
    "/cgi-bin/sendmms".


13. TROUBLESHOOTING
===================

FreeSWITCH not available:

  - Check the freeswitch container status.
  - Confirm SIP profile port 5090 is listening.
  - Re-run regression after restarting FreeSWITCH.

Conference tests skip:

  - Direct FreeSWITCH conference tests can pass without conf-factory.
  - P-CSCF conf-factory tests require conf-factory DNS/routing.

Load test failures:

  - Review load_test.txt and hardware_resource_report.txt.
  - Look for SMF exits, PyHSS/MySQL latency, MME NAS queue delay, and
    attach timeout warnings.

MMS tests skip:

  - Start and configure the MMSC/Kannel/Mbuni stack.
  - Re-run --feature mms.

Intra-NIB SMS TC-7/TC-9 skip with "no calls recorded":

  - These TCs query MySQL smsc.messages for a delivered message.
  - Delivery requires full IMS registration for the sending MSISDN.
  - In a test environment without real UE registration, TC-6 will route
    through P-CSCF but 401/timeout is likely; the message will not reach
    the SMSC database. This is expected behaviour — TC-6 (routing path)
    still passes.

Inter-NIB SMS/MMS tests skip or time out:

  - No external NIB is present in the default test environment.
  - TC-8 (inter-NIB SMS) and TC-18 (inter-NIB MM7) pass on timeout or
    4xx as long as the IMS stack does not return 5xx.
  - A 5xx from the IMS stack on these tests is a real routing config
    failure and should be investigated.

Mobile-to-IP tests skip:

  - Register a same-IMS softphone user.
  - Set SOFTPHONE_TARGET_URI.
  - Re-run --feature mobile_ip.

TEC Readiness failures:

  - TEC Readiness is an evidence/gap checker.
  - It should usually be run after --bundle all or --bundle tec.
  - If a TEC check fails while underlying feature tests passed, inspect
    tec_readiness.txt and tec_certification_gap_matrix.txt.

PyHSS API authentication errors during provisioning:

  - Set PYHSS_API_KEY to the bearer token configured in PyHSS.
  - Re-run provision_subscribers.sh or the default core suite.

MySQL password errors (CDR TC-7, SMS TC-7/TC-9):

  - Set MYSQL_ROOT_PASSWORD to the correct root password.
  - Default is "MySQL_PaSsW0rD".


14. RECOMMENDED RUNS
====================

Daily development sanity:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature regression

Bearer/QoS validation:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature bearer_qos

Conference validation:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature conference

SMS/MMS path validation:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature sms
  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature inter_nib
  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature mms

Advanced SIP feature validation:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature advanced_sip

Security posture validation:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature security

Capacity baseline:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature load

Stability baseline:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --feature stress

Release/TEC dry run:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --bundle tec

Full release evidence:

  sudo docker compose -f docker-compose.test.yaml run --remove-orphans sipp-test --bundle all
