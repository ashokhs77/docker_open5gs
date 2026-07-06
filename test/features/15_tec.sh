#!/bin/bash
# Feature 15: TEC readiness evidence bundle
#
# This feature does not pretend that simulator-only tests are formal TEC
# certification. It maps the tracker TEC/T15 work items to the strongest
# automated evidence this 4G EPC + IMS lab can produce, and records explicit
# gaps for real-UE, RF, VoWiFi, LI, billing, HA, and 3GPP study lanes.

set +e

source /opt/test/lib/common.sh

TEC_MATRIX_FILE="${REPORT_DIR}/tec_certification_gap_matrix.txt"

tec_report_path() {
    local name="$1"
    local safe_name
    safe_name=$(echo "$name" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_')
    echo "${REPORT_DIR}/${safe_name}.txt"
}

tec_report_has_no_failures() {
    local report="$1"
    [ -f "$report" ] || return 2
    ! grep -q '^\[FAIL\]' "$report"
}

tec_report_has_pass() {
    local report="$1"
    local pattern="$2"
    [ -f "$report" ] || return 2
    grep -q "^\[PASS\].*${pattern}" "$report"
}

tec_feature_status() {
    local feature="$1"
    local report
    report=$(tec_report_path "$feature")
    if [ ! -f "$report" ]; then
        echo "missing"
    elif grep -q '^\[FAIL\]' "$report"; then
        echo "failed"
    else
        echo "available"
    fi
}

tec_matrix_init() {
    {
        echo "TEC Certification Gap Matrix - 4G EPC + IMS"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Source: docs/Core_and_IMS_Tracker_Implementation_Plan.md (T4, T15, WS1-WS7, tracker bugs)"
        echo ""
        printf "%-10s | %-22s | %-16s | %-8s | %-46s | %s\n" "Item" "Area" "Automation" "Status" "Evidence/Gaps" "Next action"
        echo "-----------|------------------------|------------------|----------|------------------------------------------------|------------------------------"
    } > "$TEC_MATRIX_FILE"
}

tec_matrix_add() {
    local item="$1"
    local area="$2"
    local automation="$3"
    local status="$4"
    local evidence="$5"
    local action="$6"
    printf "%-10s | %-22s | %-16s | %-8s | %-46s | %s\n" \
        "$item" "$area" "$automation" "$status" "$evidence" "$action" >> "$TEC_MATRIX_FILE"
}

tec_require_report_clean() {
    local feature="$1"
    local label="$2"
    local report
    report=$(tec_report_path "$feature")
    if [ ! -f "$report" ]; then
        skip "$label" "Run --bundle tec or run --feature ${feature} before this TEC evidence check"
        return 2
    fi
    if tec_report_has_no_failures "$report"; then
        pass "$label evidence available from ${feature}"
        return 0
    fi
    fail "$label evidence has failures" "Feature report ${report} contains failed test cases"
    return 1
}

run_tec_tests() {
    start_feature "TEC Readiness"
    tec_matrix_init

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: TEC evidence harness and run artifacts"
        if [ -f "${REPORT_DIR}/hardware_inventory.txt" ] && [ -f "${REPORT_DIR}/hardware_checkpoints.csv" ]; then
            pass "TEC evidence harness: reports, hardware inventory, and cgroup checkpoints are being captured"
            tec_matrix_add "T4/WS1" "Evidence harness" "common.sh reports" "pass" "hardware inventory and cgroup checkpoints captured" "Attach generated reports to TEC evidence pack"
        else
            fail "TEC evidence harness incomplete" "hardware_inventory.txt or hardware_checkpoints.csv missing"
            tec_matrix_add "T4/WS1" "Evidence harness" "common.sh reports" "fail" "hardware inventory/checkpoints missing" "Fix report generation before TEC dry run"
        fi
    fi

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: EPC attach + IMS registration baseline"
        local regression_report
        regression_report=$(tec_report_path "Regression")
        if tec_report_has_pass "$regression_report" "E2E sanity: attach=OK, IMS register=OK" && \
           tec_report_has_pass "$regression_report" "S6a Diameter" && \
           tec_report_has_pass "$regression_report" "Cx Diameter"; then
            pass "TEC baseline: EPC attach, S6a, Cx, and IMS registration evidence present"
            tec_matrix_add "WS2/T15" "Attach/Register" "regression" "pass" "S1AP/NAS/S6a/Cx/SIP AKA covered" "Use as baseline TEC functional evidence"
        else
            fail "TEC baseline attach/register evidence missing" "Regression report missing attach/register or Diameter pass evidence"
            tec_matrix_add "WS2/T15" "Attach/Register" "regression" "fail" "baseline attach/register evidence missing" "Rerun regression and inspect failed TC"
        fi
    fi

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: IMS SIP/DNS readiness"
        local volte_report vilte_report inter_report
        volte_report=$(tec_report_path "VoLTE")
        vilte_report=$(tec_report_path "ViLTE")
        inter_report=$(tec_report_path "Inter-NIB")
        if tec_report_has_no_failures "$volte_report" && tec_report_has_no_failures "$vilte_report" && tec_report_has_no_failures "$inter_report"; then
            pass "TEC IMS readiness: VoLTE, ViLTE, and Inter-NIB checks passed"
            tec_matrix_add "T15/T20" "IMS readiness" "volte/vilte/inter_nib" "pass" "DNS, SIP ports, video config, routing covered" "Keep feature reports as IMS evidence"
        else
            fail "TEC IMS readiness has failed or missing evidence" "VoLTE, ViLTE, or Inter-NIB report missing/failed"
            tec_matrix_add "T15/T20" "IMS readiness" "volte/vilte/inter_nib" "fail" "one or more IMS readiness features failed" "Fix corresponding feature before TEC dry run"
        fi
    fi

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Bearer QoS and dedicated bearer lifecycle"
        local bearer_report
        bearer_report=$(tec_report_path "Bearer QoS")
        if tec_report_has_pass "$bearer_report" "QCI-1" && \
           tec_report_has_pass "$bearer_report" "QCI-2" && \
           tec_report_has_pass "$bearer_report" "QCI-5" && \
           tec_report_has_pass "$bearer_report" "QCI-9"; then
            pass "TEC QoS: QCI-1 voice, QCI-2 video, QCI-5 IMS, QCI-9 internet evidence present"
            tec_matrix_add "T1/WS3" "Bearer/QoS" "bearer_qos" "pass" "QCI-1/2/5/9 and Rx AAR/STR covered" "Add MCX QCI when policy is defined"
        else
            fail "TEC QoS evidence missing" "Bearer QoS report lacks one or more QCI lifecycle checks"
            tec_matrix_add "T1/WS3" "Bearer/QoS" "bearer_qos" "fail" "QCI lifecycle evidence incomplete" "Fix bearer_qos failures; add MCX policy tests later"
        fi
    fi

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Attach/load/capacity evidence"
        local load_report
        load_report=$(tec_report_path "Load Test")
        if [ ! -f "$load_report" ]; then
            skip "TEC load evidence" "Load Test report missing; run --bundle tec for capacity evidence"
            tec_matrix_add "WS2/B2534" "Attach load" "load" "missing" "load report missing" "Run --bundle tec"
        elif tec_report_has_no_failures "$load_report"; then
            pass "TEC load evidence: attach/register, throughput, jitter, registered-UE, call-pair, and burst tests passed"
            tec_matrix_add "WS2/B2534" "Attach load" "load" "pass" "capacity and burst evidence captured" "Use reported thresholds as lab baseline"
        else
            fail "TEC load evidence has known gaps" "Load Test report contains failures, usually burst attach capacity below TEC target"
            tec_matrix_add "WS2/B2534" "Attach load" "load" "gap" "burst/load feature failed" "Tune PyHSS/MME/SMF and rerun load"
        fi
    fi

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Long-call, session timer, and 477 resilience"
        local stress_report
        stress_report=$(tec_report_path "Stress Test")
        if tec_report_has_pass "$stress_report" "Long-duration call" && \
           tec_report_has_pass "$stress_report" "In-dialog AAR handlers are safe"; then
            pass "TEC long-call smoke evidence: session stability and in-dialog AAR resilience covered"
            tec_matrix_add "B3019/B3293" "Long call stability" "stress" "partial" "60s automated smoke; 60m real-UE soak still manual" "Run 30/45/60/120 minute real-UE lane for closure"
        else
            fail "TEC long-call smoke evidence missing" "Stress report lacks long-duration call or in-dialog AAR safety pass"
            tec_matrix_add "B3019/B3293" "Long call stability" "stress" "fail" "stress evidence incomplete" "Fix stress feature before long real-UE soak"
        fi
    fi

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Conference and call merge infrastructure"
        local conf_report
        conf_report=$(tec_report_path "Conference")
        if tec_report_has_pass "$conf_report" "All 4 members joined conference room" && \
           tec_report_has_pass "$conf_report" "Conference rooms 1014 and 1015 running concurrently"; then
            pass "TEC conference infrastructure: multi-member and concurrent conference evidence present"
            tec_matrix_add "T3/B3285" "Conference/merge" "conference" "partial" "FreeSWITCH conference covered; real UE REFER/Replaces merge still manual" "Enable conf-factory DNS and add real-UE 4-party merge"
        else
            fail "TEC conference infrastructure evidence missing" "Conference report lacks multi-member or concurrent conference pass"
            tec_matrix_add "T3/B3285" "Conference/merge" "conference" "fail" "conference automation incomplete" "Fix conference feature and enable conf-factory routing"
        fi
    fi

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: SMS and MMS evidence"
        local sms_report mms_report
        sms_report=$(tec_report_path "SMS")
        mms_report=$(tec_report_path "MMS")
        if tec_report_has_no_failures "$sms_report"; then
            if [ -f "$mms_report" ] && grep -q 'MMSC container .*not running' "$mms_report"; then
                skip "TEC messaging: SMS passes, MMS optional component not deployed" "MMSC is not running in default deployment; enable MMSC to cover MMS TEC evidence"
                tec_matrix_add "T5/T6/WS5" "SMS/MMS" "sms/mms" "partial" "SMS covered; MMS skipped because MMSC absent" "Deploy MMSC and rerun --feature mms"
            elif tec_report_has_no_failures "$mms_report"; then
                pass "TEC messaging: SMS and MMS evidence passed"
                tec_matrix_add "T5/T6/WS5" "SMS/MMS" "sms/mms" "pass" "SMS and MMS feature evidence passed" "Add delivery receipts and persistence depth tests"
            else
                fail "TEC messaging has MMS failures" "MMS report contains failures"
                tec_matrix_add "T5/T6/WS5" "SMS/MMS" "sms/mms" "gap" "MMS feature failed" "Fix MMSC/Kannel/Mbuni path"
            fi
        else
            fail "TEC SMS evidence missing or failed" "SMS report missing or failed"
            tec_matrix_add "T5/T6/WS5" "SMS/MMS" "sms/mms" "fail" "SMS baseline missing" "Fix SMS before TEC messaging dry run"
        fi
    fi

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Mobile-to-IP and softphone path"
        local mobile_report
        mobile_report=$(tec_report_path "Mobile-to-IP")
        if [ -n "${SOFTPHONE_TARGET_URI:-}" ] && tec_report_has_no_failures "$mobile_report"; then
            pass "TEC mobile-to-IP: same-IMS softphone target evidence passed"
            tec_matrix_add "T15/T20" "Mobile-to-IP" "mobile_ip" "pass" "same-IMS softphone path covered" "Keep target registration evidence"
        else
            skip "TEC mobile-to-IP path" "Set SOFTPHONE_TARGET_URI to a same-IMS registered SIP user and rerun mobile_ip/tec"
            tec_matrix_add "T15/T20" "Mobile-to-IP" "mobile_ip" "manual" "softphone target not configured" "Configure SOFTPHONE_TARGET_URI"
        fi
    fi

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Real-UE RF/media acceptance lane"
        skip "TEC real-UE RF/media acceptance" "Simulator cannot prove cell-edge RSRP/SINR, one-way audio, handset UI, or real ViLTE preparing-video behavior"
        tec_matrix_add "B2999/B3113" "Real UE/RF/media" "manual" "manual" "requires UE/eNB/attenuator/RTP evidence" "Run field-lab procedure with RF and RTP captures"
    fi

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: VoWiFi/ePDG acceptance lane"
        skip "TEC VoWiFi/ePDG acceptance" "VoWiFi requires ePDG/SWu/IPsec and handset WiFi calling setup outside the default 4G EPC+IMS deployment"
        tec_matrix_add "T8" "VoWiFi" "manual" "manual" "ePDG/SWu not in default 4G run" "Deploy VoWiFi profile and add UE acceptance"
    fi

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Analog FXO/FXS and ringback path"
        skip "TEC analog FXO/FXS and ringback path" "Tracker T9 requires the confirmed production analog path; current FXO/FXS tests are intentionally disabled"
        tec_matrix_add "T9" "Analog/RBT" "fxo_fxs" "manual" "production analog path not confirmed" "Confirm FXO/FXS/IBCF gateway and re-enable tests"
    fi

    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: LI, billing, HA, 3GPP study, NB-IoT, NTN"
        skip "TEC study/deployment lanes" "LI, billing integration, HA/K8s, 3GPP release study, NB-IoT, and NTN are tracker study/deployment tracks, not current 4G simulator runtime tests"
        tec_matrix_add "T10-T20" "Study/deployment" "manual" "manual" "not implemented in current 4G lab" "Create requirement matrices and dedicated acceptance plans"
    fi

    log "TEC matrix written to: ${TEC_MATRIX_FILE}"
    end_feature
}
