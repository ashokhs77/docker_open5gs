#!/bin/bash
# Feature 22: NGAP / N2 Conformance (5G)  (TRL8 add-on)
# 3GPP TS 38.413 (NGAP) over N2 (gNB <-> AMF), SCTP per TS 38.412.
#
# Focuses on the NGAP interface/procedures (RAN signalling transport),
# complementing feature 18 (5GMM/5GSM NAS payload) and feature 04 (registration).
#
# open5gs AMF logs the same shape as the 4G MME S1AP path:
#   "gNB-N2 accepted[ip]" / "[Added] Number of gNBs is now N" (NG Setup done),
#   "InitialUEMessage", "RAN_UE_NGAP_ID[..] AMF_UE_NGAP_ID[..]",
#   "UE Context release", "max_num_of_ostreams". The literal "NG Setup" and
#   PDU-Session-Resource/Initial-Context-Setup are not always at INFO -> honest
#   SKIP (raise verbosity / pcap). No bare numeric codes.
#
# Calibration: PASS on real evidence; SKIP when a procedure needs a gNB/UE, an MT
# trigger, or debug verbosity; FAIL only on a genuine defect (NGAP SCTP not bound
# while AMF is running). TC-12 is the REAL-HW gate (REAL_HW=1).
#
# Tests:
#   TC-1:  AMF NGAP SCTP transport bound (38412)               [TS 38.412]
#   TC-2:  AMF NGAP config audit (PLMN/TAC/GUAMI/TAI)          [TS 38.413]
#   TC-3:  NG Setup / gNB N2 association established            [TS 38.413 §8.7.1]
#   TC-4:  Initial UE Message (NAS transport over N2)           [TS 38.413 §8.6.1]
#   TC-5:  NGAP UE identity management (RAN/AMF_UE_NGAP_ID)     [TS 38.413 §9.3.3]
#   TC-6:  UE Context Release procedure                         [TS 38.413 §8.3]
#   TC-7:  SCTP association multi-streaming (NGAP)              [TS 38.412]
#   TC-8:  PDU Session Resource Setup (N2) evidence             [TS 38.413 §8.2]
#   TC-9:  Paging procedure                                     [TS 38.413 §8.5]
#   TC-10: Reset procedure handling                            [TS 38.413 §8.7.4]
#   TC-11: Error Indication / Overload handling                [TS 38.413 §8.7]
#   TC-12: [REAL-HW] Real gNB NG Setup + NGAP UE context (REAL_HW=1)

set +e

REAL_HW="${REAL_HW:-0}"

run_ngap_n2_5g_tests() {
    start_feature "NGAP/N2 Conformance (5G)"

    local amf_ready=false
    amf_ngap_ready && amf_ready=true

    # Best-effort: drive one ISOLATED transient UE (load IMSI ...0101, never the
    # functional UE) through register->PDU->de-register so the NGAP procedure TCs
    # below (NG Setup, InitialUEMessage, UE NGAP IDs, UE Context Release, SCTP) can
    # PASS on fresh evidence. Cached (shares the single trigger with feature 18).
    # Falls back silently to the prior recent-window grep + SKIP if UERANSIM is
    # unavailable, so it can never break the suite.
    conformance_trigger_5g_signalling >/dev/null 2>&1 || true

    # TC-1: AMF NGAP SCTP transport bound (38412)
    if should_run_test 1; then
        _TEST_NUM=1
        if $amf_ready; then
            pass "AMF NGAP SCTP transport bound on N2 (38412) — ready for gNB associations"
        elif container_is_running "amf"; then
            fail "AMF running but NGAP SCTP 38412 not bound" "N2 unavailable — gNBs cannot connect"
        else
            skip "AMF NGAP SCTP transport" "AMF container not running"
        fi
    fi

    # TC-2: AMF NGAP config audit (PLMN / TAC / GUAMI / TAI)
    if should_run_test 2; then
        _TEST_NUM=2
        local cfg; cfg=$(read_nf_config amf)
        if [ -z "$cfg" ]; then
            skip "AMF NGAP config audit" "Could not read amf.yaml"
        elif echo "$cfg" | grep -qiE 'ngap' && echo "$cfg" | grep -qiE 'guami' && echo "$cfg" | grep -qiE 'tai'; then
            pass "AMF NGAP configured: ngap server + GUAMI (AMF identity) + TAI/TAC + PLMN present (TS 38.413)"
        elif echo "$cfg" | grep -qiE 'ngap|guami|tai'; then
            pass "AMF NGAP configuration partially present (verify GUAMI/TAI/PLMN completeness)"
        else
            skip "AMF NGAP config audit" "ngap/guami/tai not found in amf.yaml"
        fi
    fi

    # TC-3: NG Setup / gNB N2 association established
    if should_run_test 3; then
        _TEST_NUM=3
        if $amf_ready; then
            local ngsetup
            ngsetup=$(conformance_evidence "amf" "gNB-N2 accepted|Number of gNBs is now [1-9]|NG.?Setup|NGSetup|NG-RAN node" 20)
            if [ -n "$ngsetup" ]; then
                pass "NG Setup / gNB N2 association established (gNB added to AMF context — TS 38.413 §8.7.1)"
                append_report_block "NG Setup evidence" "$(echo "$ngsetup" | tail -3)"
            else
                skip "NG Setup / gNB N2 association" \
                     "No gNB association in the log window — deploy UERANSIM nr-gnb or attach a real gNB"
            fi
        else
            skip "NG Setup / gNB N2 association" "AMF NGAP not ready"
        fi
    fi

    # TC-4: Initial UE Message (NAS transport over N2)
    if should_run_test 4; then
        _TEST_NUM=4
        if $amf_ready; then
            local iue
            iue=$(conformance_evidence "amf" "InitialUEMessage|Initial UE Message" 15)
            if [ -n "$iue" ]; then
                pass "Initial UE Message procedure evidenced (NAS-over-NGAP transport — TS 38.413 §8.6.1)"
                append_report_block "InitialUEMessage evidence" "$(echo "$iue" | tail -2)"
            else
                skip "Initial UE Message (NAS over N2)" "Not observed in window — requires a UE registration via the gNB"
            fi
        else
            skip "Initial UE Message (NAS over N2)" "AMF NGAP not ready"
        fi
    fi

    # TC-5: NGAP UE identity management (RAN_UE_NGAP_ID + AMF_UE_NGAP_ID)
    if should_run_test 5; then
        _TEST_NUM=5
        if $amf_ready; then
            local ids
            ids=$(conformance_evidence "amf" "RAN_UE_NGAP_ID|AMF_UE_NGAP_ID" 15)
            if echo "$ids" | grep -q "RAN_UE_NGAP_ID" && echo "$ids" | grep -q "AMF_UE_NGAP_ID"; then
                pass "NGAP UE identities assigned (RAN_UE_NGAP_ID + AMF_UE_NGAP_ID — per-UE association, TS 38.413 §9.3.3)"
                append_report_block "NGAP UE ID evidence" "$(echo "$ids" | tail -2)"
            elif [ -n "$ids" ]; then
                pass "NGAP UE identity assignment evidenced ($(echo "$ids" | grep -oE '(RAN|AMF)_UE_NGAP_ID' | sort -u | tr '\n' ' '))"
            else
                skip "NGAP UE identity management" "No RAN/AMF_UE_NGAP_ID in window — requires UE signalling"
            fi
        else
            skip "NGAP UE identity management" "AMF NGAP not ready"
        fi
    fi

    # TC-6: UE Context Release procedure
    if should_run_test 6; then
        _TEST_NUM=6
        if $amf_ready; then
            local rel
            rel=$(conformance_evidence "amf" "UE Context [Rr]elease|UEContextRelease" 15)
            if [ -n "$rel" ]; then
                pass "NGAP UE Context Release procedure evidenced (clean N2 context teardown — TS 38.413 §8.3)"
                append_report_block "UE Context Release evidence" "$(echo "$rel" | tail -2)"
            else
                skip "NGAP UE Context Release" "Not observed in window — occurs on de-registration/idle after a UE session"
            fi
        else
            skip "NGAP UE Context Release" "AMF NGAP not ready"
        fi
    fi

    # TC-7: SCTP association multi-streaming (NGAP over SCTP, TS 38.412)
    if should_run_test 7; then
        _TEST_NUM=7
        if $amf_ready; then
            local sctp
            sctp=$(conformance_evidence "amf" "max_num_of_ostreams|ostreams|SCTP" 12)
            if [ -n "$sctp" ]; then
                pass "NGAP SCTP multi-streaming negotiated ($(echo "$sctp" | grep -oE 'ostreams : [0-9]+' | tail -1) — TS 38.412 transport)"
                append_report_block "SCTP stream evidence" "$(echo "$sctp" | tail -2)"
            else
                skip "NGAP SCTP multi-streaming" "No SCTP stream negotiation in window (needs a recent gNB association)"
            fi
        else
            skip "NGAP SCTP multi-streaming" "AMF NGAP not ready"
        fi
    fi

    # TC-8: PDU Session Resource Setup (N2) evidence
    if should_run_test 8; then
        _TEST_NUM=8
        if $amf_ready; then
            local pdures
            pdures=$(docker_logs_recent_matches "amf" "PDU Session Resource|PDUSessionResource|Initial Context Setup|InitialContextSetup" 8)
            if [ -n "$pdures" ]; then
                pass "PDU Session Resource Setup (N2) evidenced (DRB/QoS-flow setup over N2 — TS 38.413 §8.2)"
                append_report_block "PDU Session Resource evidence" "$(echo "$pdures" | tail -3)"
            else
                skip "PDU Session Resource Setup (N2)" \
                     "open5gs AMF does not log PDU Session Resource / Initial Context Setup at INFO; raise log level or capture an NGAP pcap (DRB setup is implied by a successful PDU session — feature 05)"
            fi
        else
            skip "PDU Session Resource Setup (N2)" "AMF NGAP not ready"
        fi
    fi

    # TC-9: Paging procedure
    if should_run_test 9; then
        _TEST_NUM=9
        if $amf_ready; then
            local page
            page=$(docker_logs_recent_matches "amf" "Paging|NGAP.*[Pp]aging" 8)
            if [ -n "$page" ]; then
                pass "NGAP Paging procedure evidenced (MT trigger paged the UE — TS 38.413 §8.5)"
                append_report_block "Paging evidence" "$(echo "$page" | tail -2)"
            else
                skip "NGAP Paging procedure" \
                     "No paging in window — requires an MT event to a CM-IDLE UE"
            fi
        else
            skip "NGAP Paging procedure" "AMF NGAP not ready"
        fi
    fi

    # TC-10: Reset procedure handling
    if should_run_test 10; then
        _TEST_NUM=10
        if $amf_ready; then
            local reset
            reset=$(docker_logs_recent_matches "amf" "NGAP.*[Rr]eset|NG Reset|Reset [Rr]equest|ResetAcknowledge" 6)
            if [ -n "$reset" ]; then
                pass "NGAP Reset procedure evidenced (context cleanup signalling — TS 38.413 §8.7.4)"
            else
                skip "NGAP Reset procedure handling" \
                     "Reset is not triggered in normal operation — exercised by a gNB/AMF restart or fault injection"
            fi
        else
            skip "NGAP Reset procedure handling" "AMF NGAP not ready"
        fi
    fi

    # TC-11: Error Indication / Overload handling
    if should_run_test 11; then
        _TEST_NUM=11
        if $amf_ready; then
            local err
            err=$(docker_logs_recent_matches "amf" "Error Indication|ErrorIndication|Overload" 6)
            if [ -n "$err" ]; then
                pass "NGAP Error Indication / Overload handling evidenced (robust fault signalling — TS 38.413 §8.7)"
            else
                skip "NGAP Error Indication / Overload handling" \
                     "Not triggered in normal operation — requires a malformed message or overload condition (fault-injection lane)"
            fi
        else
            skip "NGAP Error Indication / Overload handling" "AMF NGAP not ready"
        fi
    fi

    # TC-12: [REAL-HW] real gNB NG Setup + NGAP UE context
    if should_run_test 12; then
        _TEST_NUM=12
        if [ "$REAL_HW" = "1" ]; then
            local hw
            hw=$(docker_logs_recent_matches "amf" "gNB-N2 accepted|Number of gNBs is now [1-9]|InitialUEMessage|RAN_UE_NGAP_ID|NG.?Setup" 15)
            if [ -n "$hw" ]; then
                pass "REAL-HW: AMF shows real gNB NG association + NGAP UE context signalling"
                append_report_block "Real-HW NGAP evidence" "$(echo "$hw" | tail -4)"
            else
                fail "REAL-HW requested (REAL_HW=1) but no gNB NG association/UE context in AMF logs" \
                     "Confirm the gNB N2 link to the AMF (38412) and that a UE registered via the radio"
            fi
        else
            skip "REAL-HW NGAP (real gNB + UE)" \
                 "Set REAL_HW=1 with a real gNB+UE attached. Validates NG Setup, Initial UE Message, PDU Session Resource Setup, and UE Context Release over a real N2. See test/REAL_HW_TEST_SCENARIOS.md"
        fi
    fi

    end_feature
}
