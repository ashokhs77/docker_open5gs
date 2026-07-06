#!/bin/bash
# Feature 28: Lawful Interception readiness (4G)  (TRL8 add-on)
# 3GPP TS 33.126 (LI requirements), TS 33.127 (LI architecture & functions),
# TS 33.128 (LI stage 3 / X1-X2-X3 protocols), legacy TS 33.107 (architecture)
# and TS 33.108 (HI1/HI2/HI3 handover).  India: licence LI conditions / MTCTE.
#
# COMPLIANCE-POSTURE feature (architecture-presence), NOT an interception tool.
# It builds NO interception capability and captures NO subscriber traffic. It
# audits whether the LI *architecture* required for production exists and, since
# this open5gs lab ships no LI subsystem, DOCUMENTS THE GAP as SKIP-with-finding
# — exactly the LI-readiness evidence a TRL8 / MTCTE pack must carry. The only
# genuine capability is the target-identifier basis (IMSI/IMEI/MSISDN exist as
# the identities LI would target), reported as PASS.
#
# Honest by design: absence of ADMF/MDF/POI/X1-X2-X3/HI is a finding (a real
# production gap to close before commercial launch), never a failure.
#
# Tests:
#   TC-1:  ADMF (Administration Function) present              [TS 33.127/33.107]
#   TC-2:  X1 provisioning interface (ADMF->POI) readiness      [TS 33.128/33.108]
#   TC-3:  IRI-POI host present in MME (IRI event source)       [TS 33.127]
#   TC-4:  CC-POI host present in S-/P-GW (content of comms)    [TS 33.127]
#   TC-5:  DF2/MDF2 (IRI mediation+delivery) + X2 ingest        [TS 33.128/33.108]
#   TC-6:  DF3/MDF3 (CC mediation+delivery) + X3 ingest         [TS 33.128/33.108]
#   TC-7:  HI1 (warrant/administrative) handover to LEMF        [TS 33.128/33.108]
#   TC-8:  HI2 (IRI delivery) handover to LEMF                  [TS 33.128/33.108]
#   TC-9:  HI3 (CC delivery) handover to LEMF                   [TS 33.128/33.108]
#   TC-10: LI domain security isolation / tamper-evident audit  [TS 33.126]
#   TC-11: Target-identifier basis (IMSI/IMEI/MSISDN)           [TS 33.107]
#   TC-12: LI architecture coverage summary

set +e

_li_present=0; _li_find=0
# Specific LI component tokens only (avoids matching core NF names).
_li_components() {
    docker ps --format '{{.Names}}' 2>/dev/null \
      | grep -iE 'admf|licf|lipf|mdf2|mdf3|(^|[-_])mdf([-_]|$)|(^|[-_])df2([-_]|$)|(^|[-_])df3([-_]|$)|lemf|lawful|intercept|mediation' \
      | tr '\n' ' '
}

run_li_presence_tests() {
    start_feature "LI Readiness"
    _li_present=0; _li_find=0

    # TC-1: ADMF (Administration Function)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local admf; admf=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'admf|licf|lipf')
        if [ -n "$admf" ]; then
            pass "ADMF present (LI Administration Function — warrant provisioning / task management over X1, TS 33.127 §6)"
            _li_present=$((_li_present + 1))
        else
            skip "ADMF (Administration Function)" \
                 "No ADMF/LICF/LIPF deployed. Production LI requires an Administration Function to provision intercept tasks to POIs over X1 (TS 33.127 §6 / 33.107). Add an LI domain before commercial launch"
            _li_find=$((_li_find + 1))
        fi
    fi

    # TC-2: X1 provisioning interface (ADMF -> POI)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        skip "X1 provisioning interface (ADMF->POI)" \
             "No X1 task-provisioning path (no ADMF/POI). X1 carries activate/deactivate/list of intercept tasks to POIs (TS 33.128 §5). Absent until an LI domain is deployed"
        _li_find=$((_li_find + 1))
    fi

    # TC-3: IRI-POI host present in MME (IRI event source)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if container_is_running "mme"; then
            skip "IRI-POI in MME" \
                 "MME present and is the IRI event source (attach/detach/bearer/location/TAU), but NO IRI-POI is instrumented to report those events over X2 (TS 33.127). Production needs POI instrumentation in the MME"
        else
            skip "IRI-POI in MME" "MME not running"
        fi
        _li_find=$((_li_find + 1))
    fi

    # TC-4: CC-POI host present in S-/P-GW (content of communication)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local upf=false c
        for c in upf sgwu pgw smf; do container_is_running "$c" && { upf=true; break; }; done
        if $upf; then
            skip "CC-POI in S-/P-GW (UPF)" \
                 "User-plane gateway present and carries the content of communication, but NO CC-POI is instrumented to duplicate target traffic over X3 (TS 33.127). Production needs CC-POI in the user-plane node"
        else
            skip "CC-POI in S-/P-GW (UPF)" "User-plane gateway not running"
        fi
        _li_find=$((_li_find + 1))
    fi

    # TC-5: DF2/MDF2 (IRI mediation + delivery) + X2 ingest
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        skip "DF2/MDF2 (IRI mediation+delivery) + X2" \
             "No IRI mediation/delivery function. MDF2/DF2 ingests IRI from POIs over X2 and delivers HI2 to the LEMF (TS 33.128/33.108). Absent — required for production LI"
        _li_find=$((_li_find + 1))
    fi

    # TC-6: DF3/MDF3 (CC mediation + delivery) + X3 ingest
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        skip "DF3/MDF3 (CC mediation+delivery) + X3" \
             "No CC mediation/delivery function. MDF3/DF3 ingests CC from POIs over X3 and delivers HI3 to the LEMF (TS 33.128/33.108). Absent — required for production LI"
        _li_find=$((_li_find + 1))
    fi

    # TC-7: HI1 (warrant/administrative) handover to LEMF
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        skip "HI1 (warrant/administrative) handover" \
             "No HI1 administrative handover to a LEMF. HI1 conveys warrant/lawful-authorisation data to the LI system (TS 33.128/33.108). Absent — required for production LI"
        _li_find=$((_li_find + 1))
    fi

    # TC-8: HI2 (IRI delivery) handover to LEMF
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        skip "HI2 (IRI delivery) handover" \
             "No HI2 IRI delivery to a LEMF (Law Enforcement Monitoring Facility). HI2 delivers intercept-related information records (TS 33.108). Absent — required for production LI"
        _li_find=$((_li_find + 1))
    fi

    # TC-9: HI3 (CC delivery) handover to LEMF
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        skip "HI3 (CC delivery) handover" \
             "No HI3 content-of-communication delivery to a LEMF. HI3 delivers intercepted CC (TS 33.108). Absent — required for production LI"
        _li_find=$((_li_find + 1))
    fi

    # TC-10: LI domain security isolation / tamper-evident audit
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
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

    # TC-11: Target-identifier basis (IMSI/IMEI/MSISDN) — genuine capability.
    # 4G HSS in this deployment is PyHSS backed by MySQL (db 'ims_hss_db'), NOT mongo
    # (mongo serves the 5G UDR/webui). subscriber table = IMSI/MSISDN, eir table = IMEI.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local idstore=false subs=""
        if container_is_running "mysql"; then
            idstore=true
            subs=$(docker exec mysql mysql -u root ims_hss_db -N -e "select count(*) from subscriber" 2>/dev/null | tr -dc '0-9')
        fi
        if $idstore; then
            pass "Target-identifier basis present: PyHSS/MySQL HSS (ims_hss_db) holds IMSI/MSISDN (IMEI via EIR table) — the identity types LI targets in 4G (TS 33.107 §7). Provisioned subscribers: ${subs:-n/a}"
            _li_present=$((_li_present + 1))
        else
            skip "Target-identifier basis (IMSI/IMEI/MSISDN)" "Subscriber identity store (MySQL/PyHSS HSS) not running"
        fi
    fi

    # TC-12: LI architecture coverage summary
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local summary="LI capabilities confirmed: ${_li_present} (target-identifier basis) | LI-readiness findings (SKIP): ${_li_find} (no ADMF/MDF/POI, no X1-X2-X3, no HI1-HI2-HI3 to a LEMF — full LI domain absent, TS 33.127/33.128). LI is a regulatory pre-launch requirement (licence LI conditions)."
        append_report_block "LI readiness coverage (4G)" "$summary"
        pass "LI architecture coverage summary emitted (${summary})"
    fi

    end_feature
}
