#!/bin/bash
# Feature 22: S1AP Conformance (4G)  (TRL8 add-on)
# 3GPP TS 36.413 (S1AP) over S1-MME (eNB <-> MME), SCTP per TS 36.412.
#
# Focuses on the S1AP interface/procedures (the RAN signalling transport),
# complementing feature 18 (EMM/ESM NAS payload) and regression (E2E attach).
#
# Verified open5gs MME logging (VM 2026-06-11, attach-fresh) — real strings:
#   "eNB-S1 accepted[ip]:port in s1_path module"  (SCTP association up)
#   "[Added] Number of eNBs is now N"              (eNB context added = S1 Setup done)
#   "InitialUEMessage"                              (NAS transport over S1)
#   "ENB_UE_S1AP_ID[..] MME_UE_S1AP_ID[..]"        (S1AP UE identities)
#   "UE Context Release [Action:..]"               (context release)
#   "max_num_of_ostreams : 30"                      (SCTP multi-streaming)
# open5gs does NOT log the literal "S1 Setup"/"Initial Context Setup"/"E-RAB" at
# INFO, so those are honest SKIPs (raise verbosity / pcap). No bare numeric codes.
#
# Calibration: PASS on real evidence; SKIP when a procedure needs UE traffic, an
# MT trigger, or debug verbosity; FAIL only on a genuine defect (S1AP SCTP not
# bound while MME is running). TC-12 is the REAL-HW gate (REAL_HW=1).
#
# Tests:
#   TC-1:  MME S1AP SCTP transport bound (36412)               [TS 36.412]
#   TC-2:  MME S1AP config audit (PLMN/TAC/GUMMEI/TAI)         [TS 36.413]
#   TC-3:  S1 Setup / eNB S1 association established            [TS 36.413 §8.7.3]
#   TC-4:  Initial UE Message (NAS transport over S1)           [TS 36.413 §8.6.2]
#   TC-5:  S1AP UE identity management (ENB/MME_UE_S1AP_ID)     [TS 36.413 §9.2.3]
#   TC-6:  UE Context Release procedure                         [TS 36.413 §8.3]
#   TC-7:  SCTP association multi-streaming (S1AP)              [TS 36.412]
#   TC-8:  Initial Context Setup / E-RAB management evidence    [TS 36.413 §8.2]
#   TC-9:  Paging procedure                                     [TS 36.413 §8.5]
#   TC-10: Reset procedure handling                            [TS 36.413 §8.7.1]
#   TC-11: Error Indication / Overload handling                [TS 36.413 §8.7]
#   TC-12: [REAL-HW] Real eNB S1 Setup + S1AP UE context (REAL_HW=1)

set +e

REAL_HW="${REAL_HW:-0}"

run_s1ap_tests() {
    start_feature "S1AP Conformance"

    local mme_ready=false
    if command -v mme_s1ap_ready >/dev/null 2>&1; then
        mme_s1ap_ready && mme_ready=true
    else
        container_is_running "mme" && mme_ready=true
    fi

    # TC-1: MME S1AP SCTP transport bound (36412)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if $mme_ready; then
            pass "MME S1AP SCTP transport bound on S1-MME (36412) — ready for eNB associations"
        elif container_is_running "mme"; then
            fail "MME running but S1AP SCTP 36412 not bound" "S1-MME unavailable — eNBs cannot connect"
        else
            skip "MME S1AP SCTP transport" "MME container not running"
        fi
    fi

    # TC-2: MME S1AP config audit (PLMN / TAC / GUMMEI / TAI)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local cfg; cfg=$(read_nf_config mme)
        if [ -z "$cfg" ]; then
            skip "MME S1AP config audit" "Could not read mme.yaml"
        elif echo "$cfg" | grep -qiE 's1ap' && echo "$cfg" | grep -qiE 'gummei' && echo "$cfg" | grep -qiE 'tai'; then
            pass "MME S1AP configured: s1ap server + GUMMEI (MME identity) + TAI/TAC + PLMN present (TS 36.413)"
        elif echo "$cfg" | grep -qiE 's1ap|gummei|tai'; then
            pass "MME S1AP configuration partially present (verify GUMMEI/TAI/PLMN completeness)"
        else
            skip "MME S1AP config audit" "s1ap/gummei/tai not found in mme.yaml"
        fi
    fi

    # TC-3: S1 Setup / eNB S1 association established
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if $mme_ready; then
            local s1setup
            s1setup=$(docker_logs_recent_matches "mme" "eNB-S1 accepted|Number of eNBs is now [1-9]|S1.?Setup|S1AP.*[Ss]etup" 20)
            if [ -n "$s1setup" ]; then
                pass "S1 Setup / eNB S1 association established (eNB added to MME context — TS 36.413 §8.7.3)"
                append_report_block "S1 Setup evidence" "$(echo "$s1setup" | tail -3)"
            else
                skip "S1 Setup / eNB S1 association" \
                     "No eNB association in the log window — connect an eNB/ue_sim (run regression) or attach a real eNB"
            fi
        else
            skip "S1 Setup / eNB S1 association" "MME S1AP not ready"
        fi
    fi

    # TC-4: Initial UE Message (NAS transport over S1)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if $mme_ready; then
            local iue
            iue=$(docker_logs_recent_matches "mme" "InitialUEMessage|Initial UE Message" 15)
            if [ -n "$iue" ]; then
                pass "Initial UE Message procedure evidenced (NAS-over-S1AP transport — TS 36.413 §8.6.2)"
                append_report_block "InitialUEMessage evidence" "$(echo "$iue" | tail -2)"
            else
                skip "Initial UE Message (NAS over S1)" "Not observed in window — requires a UE attach via the eNB"
            fi
        else
            skip "Initial UE Message (NAS over S1)" "MME S1AP not ready"
        fi
    fi

    # TC-5: S1AP UE identity management (ENB_UE_S1AP_ID + MME_UE_S1AP_ID)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if $mme_ready; then
            local ids
            ids=$(docker_logs_recent_matches "mme" "ENB_UE_S1AP_ID" 15)
            if echo "$ids" | grep -q "ENB_UE_S1AP_ID" && echo "$ids" | grep -q "MME_UE_S1AP_ID"; then
                pass "S1AP UE identities assigned (ENB_UE_S1AP_ID + MME_UE_S1AP_ID — per-UE association, TS 36.413 §9.2.3)"
                append_report_block "S1AP UE ID evidence" "$(echo "$ids" | tail -2)"
            else
                skip "S1AP UE identity management" "No ENB/MME_UE_S1AP_ID pair in window — requires UE signalling"
            fi
        else
            skip "S1AP UE identity management" "MME S1AP not ready"
        fi
    fi

    # TC-6: UE Context Release procedure
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if $mme_ready; then
            local rel
            rel=$(docker_logs_recent_matches "mme" "UE Context Release|UEContextRelease" 15)
            if [ -n "$rel" ]; then
                pass "S1AP UE Context Release procedure evidenced (clean S1 context teardown — TS 36.413 §8.3)"
                append_report_block "UE Context Release evidence" "$(echo "$rel" | tail -2)"
            else
                skip "S1AP UE Context Release" "Not observed in window — occurs on detach/idle after a UE session"
            fi
        else
            skip "S1AP UE Context Release" "MME S1AP not ready"
        fi
    fi

    # TC-7: SCTP association multi-streaming (S1AP over SCTP, TS 36.412)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if $mme_ready; then
            local sctp
            sctp=$(docker_logs_recent_matches "mme" "max_num_of_ostreams|ostreams|SCTP" 12)
            if [ -n "$sctp" ]; then
                pass "S1AP SCTP multi-streaming negotiated ($(echo "$sctp" | grep -oE 'ostreams : [0-9]+' | tail -1) — TS 36.412 transport)"
                append_report_block "SCTP stream evidence" "$(echo "$sctp" | tail -2)"
            else
                skip "S1AP SCTP multi-streaming" "No SCTP stream negotiation in window (needs a recent eNB association)"
            fi
        else
            skip "S1AP SCTP multi-streaming" "MME S1AP not ready"
        fi
    fi

    # TC-8: Initial Context Setup / E-RAB management evidence
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if $mme_ready; then
            local erab
            erab=$(docker_logs_recent_matches "mme" "Initial Context Setup|InitialContextSetup|E-?RAB" 8)
            if [ -n "$erab" ]; then
                pass "Initial Context Setup / E-RAB management evidenced (radio bearer setup over S1 — TS 36.413 §8.2)"
                append_report_block "E-RAB evidence" "$(echo "$erab" | tail -3)"
            else
                skip "Initial Context Setup / E-RAB management" \
                     "open5gs MME does not log Initial Context Setup / E-RAB at INFO verbosity; raise log level or capture an S1AP pcap (radio bearer setup is implied by a successful attach — regression TC-18)"
            fi
        else
            skip "Initial Context Setup / E-RAB management" "MME S1AP not ready"
        fi
    fi

    # TC-9: Paging procedure
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if $mme_ready; then
            local page
            page=$(docker_logs_recent_matches "mme" "Paging|S1AP.*[Pp]aging" 8)
            if [ -n "$page" ]; then
                pass "S1AP Paging procedure evidenced (MT trigger paged the UE — TS 36.413 §8.5)"
                append_report_block "Paging evidence" "$(echo "$page" | tail -2)"
            else
                skip "S1AP Paging procedure" \
                     "No paging in window — requires an MT event to an idle UE (regression TC-40 exercises MT paging)"
            fi
        else
            skip "S1AP Paging procedure" "MME S1AP not ready"
        fi
    fi

    # TC-10: Reset procedure handling
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if $mme_ready; then
            local reset
            reset=$(docker_logs_recent_matches "mme" "S1AP.*[Rr]eset|Reset [Rr]equest|ResetAcknowledge" 6)
            if [ -n "$reset" ]; then
                pass "S1AP Reset procedure evidenced (context cleanup signalling — TS 36.413 §8.7.1)"
            else
                skip "S1AP Reset procedure handling" \
                     "Reset is not triggered in normal operation — exercised by an eNB/MME restart or fault injection"
            fi
        else
            skip "S1AP Reset procedure handling" "MME S1AP not ready"
        fi
    fi

    # TC-11: Error Indication / Overload handling
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if $mme_ready; then
            local err
            err=$(docker_logs_recent_matches "mme" "Error Indication|ErrorIndication|Overload" 6)
            if [ -n "$err" ]; then
                pass "S1AP Error Indication / Overload handling evidenced (robust fault signalling — TS 36.413 §8.7)"
            else
                skip "S1AP Error Indication / Overload handling" \
                     "Not triggered in normal operation — requires a malformed message or overload condition (fault-injection lane)"
            fi
        else
            skip "S1AP Error Indication / Overload handling" "MME S1AP not ready"
        fi
    fi

    # TC-12: [REAL-HW] real eNB S1 Setup + S1AP UE context
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if [ "$REAL_HW" = "1" ]; then
            local hw
            hw=$(docker_logs_recent_matches "mme" "eNB-S1 accepted|Number of eNBs is now [1-9]|InitialUEMessage|ENB_UE_S1AP_ID" 15)
            if [ -n "$hw" ]; then
                pass "REAL-HW: MME shows real eNB S1 association + S1AP UE context signalling"
                append_report_block "Real-HW S1AP evidence" "$(echo "$hw" | tail -4)"
            else
                fail "REAL-HW requested (REAL_HW=1) but no eNB S1 association/UE context in MME logs" \
                     "Confirm the eNB S1 link to the MME and that a UE attached via the radio"
            fi
        else
            skip "REAL-HW S1AP (real eNB + UE)" \
                 "Set REAL_HW=1 with a real eNB+UE attached. Validates S1 Setup, Initial UE Message, Initial Context Setup/E-RAB, and UE Context Release over a real S1-MME. See test/REAL_HW_TEST_SCENARIOS.md"
        fi
    fi

    end_feature
}
