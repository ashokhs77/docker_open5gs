================================================================================
 5G SA + VoNR TEST SUITE — QUICK REFERENCE
================================================================================

Dockerized integration test suite for the 5G SA core + VoNR (IMS) side of the
docker_open5gs deployment.

  Feature groups : 31  (19 core + 12 TRL8 opt-in)
  Test cases     : 366
  Last result    : 307 PASS / 2 FAIL / 57 SKIP  (--bundle all, 2026-07-06;
                   both fails are transient UERANSIM load-ceiling TCs, pass on re-run)
  Runner image   : docker_test_5g       (test/Dockerfile.5g)
  Compose file   : docker-compose.test5g.yaml
  Compose service: sipp-test-5g
  RAN/UE sim     : UERANSIM gradiant/ueransim:3.2.6 (pulled, not compiled) -> nr-gnb/nr-ue

  ── For the full reference (feature catalog, UERANSIM detail, reports, result
     interpretation, troubleshooting) see TEST_SUITE_GUIDE_5G.md ──

Note: "sudo" is shown throughout; omit it if your user is in the docker group.


--------------------------------------------------------------------------------
 0. PREREQUISITES
--------------------------------------------------------------------------------
  # (1) REQUIRED: enable WITH_SIPP_TEST on the (shared) P-CSCF BEFORE starting the stack.
  #     VoNR/ViNR/SMS/conference tests drive the shared IMS with synthetic SIPp UE
  #     clients; this macro turns on the P-CSCF test-client bypasses. Without it those
  #     SIPp tests 4xx-fail or hang. Enabled by default at pcscf/kamailio_pcscf.cfg:20
  #     in this test branch -- verify:
  cd ~/docker_open5gs
  grep -n '^#!define WITH_SIPP_TEST' pcscf/kamailio_pcscf.cfg    # must print a match
  #     (if commented out, uncomment it; if the stack is already up, then:
  #      sudo docker restart pcscf)

  # (2) The 5G stack must be running:
  sudo docker compose -f sa-vonr-deploy.yaml up -d

  # (3) AVX-less host (QEMU/i440FX VM)? MongoDB >=5.0 SIGILLs -> use 4.4.
  #     In ~/docker_open5gs/.env set:   MONGO_IMAGE=mongo:4.4
  #     then:
  sudo docker compose -f sa-vonr-deploy.yaml up -d --force-recreate mongo
  sudo docker restart pcf bsf udr udm webui        # NFs cache the mongo connection

  # (4) Run all test commands from the test directory:
  cd ~/docker_open5gs/test


--------------------------------------------------------------------------------
 1. BUILD
--------------------------------------------------------------------------------
  # Deployment images (5G core + IMS):
  cd ~/docker_open5gs && sudo bash build_all_5g.sh

  # Test runner image (docker_test_5g) + UERANSIM (pulled):
  cd ~/docker_open5gs/test
  sudo bash build_test_5g.sh                 # runner + UERANSIM  [default]
  sudo bash build_test_5g.sh --cache         # fast incremental runner rebuild
  sudo bash build_test_5g.sh --only-runner   # runner image only
  sudo bash build_test_5g.sh --only-ueransim # pull UERANSIM only
  sudo bash build_test_5g.sh --help

  (UERANSIM is a PRE-BUILT image that is PULLED, not compiled. Override the tag with
   UERANSIM_IMG=<tag> sudo bash build_test_5g.sh)


--------------------------------------------------------------------------------
 2. UERANSIM  (5G gNB + UE — needed by RAN/UE tests; start AFTER the core is up)
--------------------------------------------------------------------------------
  # Bring up the functional gNB + UE (provisions a subscriber, launches nr-gnb/nr-ue):
  cd ~/docker_open5gs/test
  sudo bash ueransim/bringup_ueransim.sh

  # Verify:
  sudo docker ps --filter name=nr-
  sudo docker logs nr-ue 2>&1 | grep -E "Registration is successful|PDU Session"

  # STOP UERANSIM (standalone containers, not compose-managed):
  sudo docker rm -f nr-ue nr-gnb
  sudo docker rm -f $(sudo docker ps -aq --filter name=load) 2>/dev/null   # any load cells

  NOTE: the load_5g feature launches its own dedicated load cells (nr-gnb-load-0/1) —
  you do NOT start those by hand. The --bundle 5gc smoke bundle needs NO UERANSIM.


--------------------------------------------------------------------------------
 3. HELP / LIST AVAILABLE TESTS
--------------------------------------------------------------------------------
  sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --help
  sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --list


--------------------------------------------------------------------------------
 4. RUN TESTS   (all take the form: ... run --rm sipp-test-5g <ARGS>)
--------------------------------------------------------------------------------
  # One single test case (requires --feature):
  sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --feature vonr --test 3

  # One feature group:
  sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --feature registration

  # A curated bundle:
  sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --bundle 5gc   # core smoke, NO UERANSIM
  sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --bundle full  # 19 core
  sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --bundle trl8  # 12 TRL8
  sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --bundle all   # everything

  # Default core run (19 core features, no TRL8):
  sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g

  # Complete suite (31 features / 366 TCs + comprehensive report):
  sudo docker compose -f docker-compose.test5g.yaml run --rm sipp-test-5g --bundle all


--------------------------------------------------------------------------------
 5. STOP A RUN IN PROGRESS
--------------------------------------------------------------------------------
  # The test run:
  #   Foreground: press Ctrl-C (with --rm the container is removed on exit).
  sudo docker ps --filter ancestor=docker_test_5g
  sudo docker rm -f <container-id-or-name>
  sudo docker compose -f docker-compose.test5g.yaml down --remove-orphans   # sweep orphans

  # UERANSIM (separate from the test run):
  sudo docker rm -f nr-ue nr-gnb
  sudo docker rm -f $(sudo docker ps -aq --filter name=load) 2>/dev/null


--------------------------------------------------------------------------------
 6. FEATURE KEYS  (use with --feature <key>)
--------------------------------------------------------------------------------
  CORE (19) — default run / --bundle full / --bundle all
    regression_5g(23)  5gc_health(20)  nrf_sbi(10)  ausf_udm(8)  registration(9)
    pdu_session(7)  pdu_profile_5g(10)  vonr(11)  sms_5g(13)  cdr_5g(7)  slicing(7)
    security_5g(14)  mms_5g(18)  conference_5g(15)  advanced_sip_5g(5)  stress_5g(9)
    video_vonr(10)  qos_flow_5g(10)  load_5g(20)

  TRL8 (12) — opt-in: --feature <key> / --bundle trl8 / --bundle all
    nas_conformance_5g(12)  scas_itsar_5g(12)  sbi_conformance_5g(12)  pfcp_n4_5g(12)
    ngap_n2_5g(12)  ims_ng114_5g(12)  perf_kpi_5g(12)  ha_resilience_5g(12)
    oam_fcaps_5g(12)  charging_5g(12)  li_presence_5g(12)  interface_evidence_5g(8)

  5gc smoke bundle (NO UERANSIM): regression_5g, 5gc_health, nrf_sbi, ausf_udm, slicing
  (Numbers in parentheses are test-case counts.)


--------------------------------------------------------------------------------
 7. REPORTS  (written to /opt/test/reports/ inside the runner; bind-mounted to host)
--------------------------------------------------------------------------------
  summary.txt                 feature totals (quick green/red)
  detailed_test_report.txt    full human-readable report
  <feature>.txt               per-feature PASS/FAIL/SKIP + reasons
  comprehensive/TEST_REPORT_5G_latest.{md,html,json}   (only on --bundle all)


--------------------------------------------------------------------------------
 8. BUNDLES AT A GLANCE
--------------------------------------------------------------------------------
  --bundle 5gc    5 core smoke features      NO UERANSIM   fast 5GC sanity
  (no arg)        19 core features           UERANSIM      core validation
  --bundle full   19 core features           UERANSIM      core validation
  --bundle trl8   12 TRL8 features           UERANSIM      conformance/assurance
  --bundle all    31 features + report       UERANSIM      full release validation

  End-to-end:  up core -> restart pcf/bsf/udr/udm/webui -> build_test_5g.sh ->
               bringup_ueransim.sh -> run --bundle all -> rm -f nr-ue nr-gnb
================================================================================
