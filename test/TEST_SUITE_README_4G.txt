================================================================================
 4G EPC + IMS TEST SUITE — QUICK REFERENCE
================================================================================

Dockerized integration test suite for the 4G EPC + IMS (VoLTE/ViLTE) side of the
docker_open5gs deployment.

  Feature groups : 34  (22 core + 12 TRL8 opt-in)
  Test cases     : 403
  Last result    : 326 PASS / 1 FAIL / 76 SKIP  (--bundle all, 2026-07-06;
                   the 1 fail is a transient multi-UE reg timeout, passes on re-run)
  Runner image   : docker_test          (test/Dockerfile)
  Compose file   : docker-compose.test.yaml
  Compose service: sipp-test

  ── For the full reference (feature catalog, prerequisites, reports,
     result interpretation, macros, troubleshooting) see TEST_SUITE_GUIDE_4G.md ──

Note: "sudo" is shown throughout; omit it if your user is in the docker group.


--------------------------------------------------------------------------------
 0. PREREQUISITES
--------------------------------------------------------------------------------
  # (1) REQUIRED: enable WITH_SIPP_TEST on the P-CSCF BEFORE starting the stack.
  #     The suite drives the IMS with synthetic SIPp/UE clients; this macro turns
  #     on the P-CSCF test-client bypasses in the REGISTER/MO/MT routes. Without it
  #     the VoLTE/ViLTE/SMS/conference tests 4xx-fail or hang. It is enabled by
  #     default at pcscf/kamailio_pcscf.cfg:20 in this test branch -- verify:
  cd ~/docker_open5gs
  grep -n '^#!define WITH_SIPP_TEST' pcscf/kamailio_pcscf.cfg    # must print a match
  #     (if commented out, uncomment it; if the stack is already up, then:
  #      sudo docker restart pcscf)

  # (2) The 4G stack must be running:
  sudo docker compose -f 4g-volte-deploy.yaml up -d

  # (3) Run all test commands from the test directory:
  cd ~/docker_open5gs/test


--------------------------------------------------------------------------------
 1. BUILD
--------------------------------------------------------------------------------
  # Deployment images (4G core + IMS):
  cd ~/docker_open5gs && sudo bash build_all.sh

  # Test-suite runner image (developer-only) -> docker_test:
  cd ~/docker_open5gs/test
  sudo bash build_test.sh            # clean build  [default]
  sudo bash build_test.sh --cache    # fast incremental rebuild
  sudo bash build_test.sh --help

  (The 4G UE simulator is Python in test/ue_sim/, baked into the image —
   there is nothing extra to pull.)


--------------------------------------------------------------------------------
 2. HELP / LIST AVAILABLE TESTS
--------------------------------------------------------------------------------
  sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --help
  sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --list

  --list is the live source of truth for every feature and test case.


--------------------------------------------------------------------------------
 3. RUN TESTS   (all take the form: ... run --rm sipp-test <ARGS>)
--------------------------------------------------------------------------------
  # One single test case (requires --feature):
  sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --feature cdr --test 3

  # One feature group:
  sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --feature volte

  # A curated bundle:
  sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --bundle tec
  sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --bundle trl8
  sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --bundle all

  # Default core run (22 core features, no TRL8):
  sudo docker compose -f docker-compose.test.yaml run --rm sipp-test

  # Complete suite (34 features / 403 TCs + comprehensive report; ~2h on the ref VM):
  sudo docker compose -f docker-compose.test.yaml run --rm sipp-test --bundle all


--------------------------------------------------------------------------------
 4. STOP A RUN IN PROGRESS
--------------------------------------------------------------------------------
  # Foreground run: press Ctrl-C (with --rm the container is removed on exit).

  # If a runner container lingers:
  sudo docker ps --filter ancestor=docker_test
  sudo docker rm -f <container-id-or-name>

  # Sweep any orphaned runner:
  sudo docker compose -f docker-compose.test.yaml down --remove-orphans

  NOTE: regression TC-41 and ha_resilience restart core NFs on purpose. If you
  stop mid-restart, confirm the stack is healthy before re-running:
  sudo docker ps ; sudo docker exec pcscf kamcmd core.version


--------------------------------------------------------------------------------
 5. FEATURE KEYS  (use with --feature <key>)
--------------------------------------------------------------------------------
  CORE (22) — default run / --bundle tec / --bundle all
    epc_health(20)  hss_auc(10)  pdn_session(9)  pyhss_api(10)  attach_churn(9)
    regression(49)  volte(9)  vilte(11)  eir(6)  sms(13)  inter_nib(8)
    conference(15)  fxo_fxs(5)  mobile_ip(6)  cdr(7)  load(14)  mms(18)
    stress(8)  bearer_qos(10)  tec(13)  advanced_sip(5)  security(10)

  TRL8 (12) — opt-in: --feature <key> / --bundle trl8 / --bundle all
    nas_conformance(10)  scas_itsar(12)  diameter_conformance(12)  pfcp_n4(12)
    s1ap(12)  ims_ng114(12)  perf_kpi(12)  ha_resilience(12)  oam_fcaps(12)
    charging(12)  li_presence(12)  interface_evidence(8)

  (Numbers in parentheses are test-case counts.)


--------------------------------------------------------------------------------
 6. REPORTS  (written to /opt/test/reports/ inside the runner; bind-mounted to host)
--------------------------------------------------------------------------------
  summary.txt                 feature totals (quick green/red)
  detailed_test_report.txt    full human-readable report
  <feature>.txt               per-feature PASS/FAIL/SKIP + reasons
  comprehensive/TEST_REPORT_4G_latest.{md,html,json}   (only on --bundle all)


--------------------------------------------------------------------------------
 7. BUNDLES AT A GLANCE
--------------------------------------------------------------------------------
  (no arg)        22 core features                       dev/deploy smoke
  --bundle tec    22 core + TEC gap matrix               automated evidence pack
  --bundle trl8   12 TRL8 features only                  conformance/assurance
  --bundle all    34 features + comprehensive report     full release validation
================================================================================
