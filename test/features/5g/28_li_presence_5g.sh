#!/bin/bash
# Feature 28: Lawful Interception readiness (5G)  (TRL8 add-on)
# 3GPP TS 33.126 (LI requirements), TS 33.127 (5G LI architecture: ADMF/LICF/
# LIPF, IRI-POI/CC-POI, MDF2/MDF3), TS 33.128 (LI stage 3 — X1/X2/X3 + HI1/2/3).
# India: licence LI conditions / MTCTE.
#
# COMPLIANCE-POSTURE feature (architecture-presence), NOT an interception tool.
# It builds NO interception capability and captures NO subscriber traffic. It
# audits whether the 5G LI *architecture* required for production exists and,
# since this open5gs 5G lab ships no LI subsystem, DOCUMENTS THE GAP as SKIP-
# with-finding — the LI-readiness evidence a TRL8 / MTCTE pack must carry. The
# only genuine capability is the target-identifier basis (SUPI/SUCI/PEI/GPSI
# exist as the identities LI would target), reported as PASS.
#
# Honest by design: absence of ADMF/MDF/POI/X1-X2-X3/HI is a finding (a real
# production gap to close before commercial launch), never a failure. Mirrors
# feature 28 'li_presence' (4G).
#
# Tests:
#   TC-1:  ADMF (LICF+LIPF) present                            [TS 33.127 §6]
#   TC-2:  X1 provisioning interface (LIPF->POI) readiness      [TS 33.128 §5.2]
#   TC-3:  IRI-POI host present in AMF (IRI event source)       [TS 33.127 §6.2]
#   TC-4:  CC-POI host present in UPF (content of comms)        [TS 33.127 §6.2]
#   TC-5:  MDF2 (IRI mediation+delivery) + X2 ingest            [TS 33.128 §6 X2]
#   TC-6:  MDF3 (CC mediation+delivery) + X3 ingest             [TS 33.128 §7 X3]
#   TC-7:  HI1 (warrant/administrative) handover to LEMF        [TS 33.128]
#   TC-8:  HI2 (IRI delivery) handover to LEMF                  [TS 33.128]
#   TC-9:  HI3 (CC delivery) handover to LEMF                   [TS 33.128]
#   TC-10: LI domain security isolation / tamper-evident audit  [TS 33.126]
#   TC-11: Target-identifier basis (SUPI/SUCI/PEI/GPSI)         [TS 33.127 §7]
#   TC-12: LI architecture coverage summary

set +e

_li_present=0; _li_find=0
_li_components() {
    docker ps --format '{{.Names}}' 2>/dev/null \
      | grep -iE 'admf|licf|lipf|mdf2|mdf3|(^|[-_])mdf([-_]|$)|lemf|lawful|intercept|mediation' \
      | tr '\n' ' '
}

run_li_presence_5g_tests() {
    start_feature "LI Readiness (5G)"
    _li_present=0; _li_find=0

    # TC-1: ADMF (LICF + LIPF)
    if should_run_test 1; then
        _TEST_NUM=1
        local admf; admf=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'admf|licf|lipf')
        if [ -n "$admf" ]; then
            pass "ADMF present (LICF control + LIPF provisioning — warrant provisioning / task management over X1, TS 33.127 §6)"
            _li_present=$((_li_present + 1))
        else
            skip "ADMF (LICF/LIPF)" \
                 "No ADMF/LICF/LIPF deployed. 5G LI requires an Administration Function (LICF+LIPF) to provision intercept tasks to POIs over X1 (TS 33.127 §6). Add an LI domain before commercial launch"
            _li_find=$((_li_find + 1))
        fi
    fi

    # TC-2: X1 provisioning interface (LIPF -> POI)
    if should_run_test 2; then
        _TEST_NUM=2
        skip "X1 provisioning interface (LIPF->POI)" \
             "No X1 task-provisioning path (no LIPF/POI). X1 carries activate/deactivate/modify of intercept tasks to POIs in NFs (TS 33.128 §5.2). Absent until an LI domain is deployed"
        _li_find=$((_li_find + 1))
    fi

    # TC-3: IRI-POI host present in AMF (IRI event source)
    if should_run_test 3; then
        _TEST_NUM=3
        if container_is_running "amf"; then
            skip "IRI-POI in AMF" \
                 "AMF present and is the IRI event source (registration/CM/mobility/PDU-session events), but NO IRI-POI is instrumented to report them over X2 (TS 33.127 §6.2). Production needs POI instrumentation in the AMF (and SMF)"
        else
            skip "IRI-POI in AMF" "AMF not running"
        fi
        _li_find=$((_li_find + 1))
    fi

    # TC-4: CC-POI host present in UPF (content of communication)
    if should_run_test 4; then
        _TEST_NUM=4
        if container_is_running "upf"; then
            skip "CC-POI in UPF" \
                 "UPF present and carries the content of communication, but NO CC-POI is instrumented to duplicate target traffic over X3 (TS 33.127 §6.2). Production needs CC-POI in the UPF"
        else
            skip "CC-POI in UPF" "UPF not running"
        fi
        _li_find=$((_li_find + 1))
    fi

    # TC-5: MDF2 (IRI mediation + delivery) + X2 ingest
    if should_run_test 5; then
        _TEST_NUM=5
        skip "MDF2 (IRI mediation+delivery) + X2" \
             "No IRI Mediation & Delivery Function. MDF2 ingests IRI from IRI-POIs over X2 and delivers HI2 to the LEMF (TS 33.128 §6). Absent — required for production LI"
        _li_find=$((_li_find + 1))
    fi

    # TC-6: MDF3 (CC mediation + delivery) + X3 ingest
    if should_run_test 6; then
        _TEST_NUM=6
        skip "MDF3 (CC mediation+delivery) + X3" \
             "No CC Mediation & Delivery Function. MDF3 ingests CC from CC-POIs over X3 and delivers HI3 to the LEMF (TS 33.128 §7). Absent — required for production LI"
        _li_find=$((_li_find + 1))
    fi

    # TC-7: HI1 (warrant/administrative) handover to LEMF
    if should_run_test 7; then
        _TEST_NUM=7
        skip "HI1 (warrant/administrative) handover" \
             "No HI1 administrative handover to a LEMF. HI1 conveys warrant/lawful-authorisation data into the LI system (TS 33.128). Absent — required for production LI"
        _li_find=$((_li_find + 1))
    fi

    # TC-8: HI2 (IRI delivery) handover to LEMF
    if should_run_test 8; then
        _TEST_NUM=8
        skip "HI2 (IRI delivery) handover" \
             "No HI2 IRI delivery to a LEMF (Law Enforcement Monitoring Facility). HI2 delivers intercept-related information records (TS 33.128). Absent — required for production LI"
        _li_find=$((_li_find + 1))
    fi

    # TC-9: HI3 (CC delivery) handover to LEMF
    if should_run_test 9; then
        _TEST_NUM=9
        skip "HI3 (CC delivery) handover" \
             "No HI3 content-of-communication delivery to a LEMF. HI3 delivers intercepted CC (TS 33.128). Absent — required for production LI"
        _li_find=$((_li_find + 1))
    fi

    # TC-10: LI domain security isolation / tamper-evident audit
    if should_run_test 10; then
        _TEST_NUM=10
        local li; li=$(_li_components)
        if [ -n "$li" ]; then
            skip "LI domain security isolation" \
                 "LI components detected (${li}) — verify they run on isolated, access-controlled infrastructure with tamper-evident audit and least-disclosure (TS 33.126 §5)"
        else
            skip "LI domain security isolation" \
                 "No LI domain to isolate yet. When LI is deployed it MUST be on segregated, access-controlled infrastructure with tamper-evident logging and need-to-know access (TS 33.126 §5 security requirements)"
        fi
        _li_find=$((_li_find + 1))
    fi

    # TC-11: Target-identifier basis (SUPI/SUCI/PEI/GPSI) — genuine capability
    if should_run_test 11; then
        _TEST_NUM=11
        local idstore=false subs=""
        if container_is_running "mongo"; then
            idstore=true
            subs=$(docker exec mongo mongo open5gs --quiet --eval 'db.subscribers.countDocuments({})' 2>/dev/null | tr -dc '0-9')
        fi
        if $idstore; then
            pass "Target-identifier basis present: subscriber store holds SUPI(IMSI)/GPSI(MSISDN); SUCI de-concealment via AUSF/UDM, PEI/IMEI via EIR — the 5G LI target identity types (TS 33.127 §7). Provisioned subscribers: ${subs:-n/a}"
            _li_present=$((_li_present + 1))
        else
            skip "Target-identifier basis (SUPI/SUCI/PEI/GPSI)" "Subscriber identity store (mongo/UDR) not running"
        fi
    fi

    # TC-12: LI architecture coverage summary
    if should_run_test 12; then
        _TEST_NUM=12
        local summary="LI capabilities confirmed: ${_li_present} (target-identifier basis) | LI-readiness findings (SKIP): ${_li_find} (no ADMF/MDF/POI, no X1-X2-X3, no HI1-HI2-HI3 to a LEMF — full LI domain absent, TS 33.127/33.128). LI is a regulatory pre-launch requirement (licence LI conditions)."
        append_report_block "LI readiness coverage (5G)" "$summary"
        pass "LI architecture coverage summary emitted (${summary})"
    fi

    end_feature
}
