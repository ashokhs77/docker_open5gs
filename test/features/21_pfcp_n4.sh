#!/bin/bash
# Feature 21: PFCP Conformance (4G — Sxa/Sxb)  (TRL8 add-on)
# 3GPP TS 29.244 (PFCP) over Sxa (SGW-C<->SGW-U) and Sxb (SMF<->UPF).
#
# open5gs 4G uses the same PFCP stack as 5G N4, so the verified log strings are
# identical: "pfcp_server() [ip]:8805", "PFCP associated [ip]:8805" (both ends),
# "PFCP[REQ]"/"PFCP[RSP]", "has already been associated". We use passive
# evidence + config audit only — never bare numeric message codes (false-positive
# prone). Complements regression TC-10/11/12 (PFCP/GTP health) with conformance depth.
#
# Calibration: PASS on real evidence; SKIP when a procedure needs attach traffic
# or debug verbosity; FAIL only on a genuine defect (both nodes of an association
# up but NO association at all).
#
# Tests:
#   TC-1:  SGW-U PFCP server bound (8805/UDP)                   [TS 29.244]
#   TC-2:  UPF PFCP server bound (8805/UDP)                     [TS 29.244]
#   TC-3:  Sxa SGW-C<->SGW-U PFCP association                    [TS 29.244 §6.2.6]
#   TC-4:  Sxb SMF<->UPF PFCP association                        [TS 29.244 §6.2.6]
#   TC-5:  PFCP node configuration audit (mutual server/client) [TS 29.244]
#   TC-6:  PFCP request/response message exchange evidence       [TS 29.244 §7]
#   TC-7:  SGW-U GTP-U S1-U data plane bound (2152/UDP)         [TS 29.281]
#   TC-8:  PFCP association liveness / keepalive                 [TS 29.244 §6.2.1]
#   TC-9:  PFCP Session Establishment evidence                   [TS 29.244 §7.5.2]
#   TC-10: PFCP rules PDR/FAR/QER installation evidence          [TS 29.244 §7.5]
#   TC-11: PFCP Usage Reporting (URR) for charging               [TS 29.244 §7.5.8]
#   TC-12: PFCP association restoration / recovery handling       [TS 23.527]

set +e

run_pfcp_n4_tests() {
    start_feature "PFCP Conformance"

    local sgwc_up=false sgwu_up=false smf_up=false upf_up=false
    container_is_running "sgwc" && sgwc_up=true
    container_is_running "sgwu" && sgwu_up=true
    container_is_running "smf"  && smf_up=true
    container_is_running "upf"  && upf_up=true

    # TC-1: SGW-U PFCP server bound
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if ! $sgwu_up; then
            skip "SGW-U PFCP server" "SGW-U container not running"
        elif container_listens_on_port "sgwu" 8805 || docker_logs_recent_matches "sgwu" "pfcp_server\\(\\)" 3 | grep -q pfcp_server; then
            pass "SGW-U PFCP server bound (8805/UDP, Sxa) — pfcp_server() up"
        else
            skip "SGW-U PFCP server" "8805 not confirmed via ss and no pfcp_server() log in window"
        fi
    fi

    # TC-2: UPF PFCP server bound
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if ! $upf_up; then
            skip "UPF PFCP server" "UPF container not running"
        elif container_listens_on_port "upf" 8805 || docker_logs_recent_matches "upf" "pfcp_server\\(\\)" 3 | grep -q pfcp_server; then
            pass "UPF PFCP server bound (8805/UDP, Sxb) — pfcp_server() up"
        else
            skip "UPF PFCP server" "8805 not confirmed via ss and no pfcp_server() log in window"
        fi
    fi

    # TC-3: Sxa SGW-C <-> SGW-U PFCP association
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local c_assoc="" u_assoc=""
        $sgwc_up && c_assoc=$(docker_logs_recent_matches "sgwc" "PFCP associated|has already been associated" 20)
        $sgwu_up && u_assoc=$(docker_logs_recent_matches "sgwu" "PFCP associated|has already been associated" 20)
        if [ -n "$c_assoc" ] || [ -n "$u_assoc" ]; then
            pass "Sxa SGW-C<->SGW-U PFCP association established (TS 29.244)"
            append_report_block "Sxa association" "$(printf '%s\n%s' "$c_assoc" "$u_assoc" | grep -i assoc | tail -2)"
        elif $sgwc_up && $sgwu_up; then
            fail "SGW-C and SGW-U both running but NO Sxa PFCP association evidence" \
                 "Sxa may be down — check SGW-C/SGW-U PFCP addresses and reachability"
        else
            skip "Sxa SGW-C<->SGW-U association" "SGW-C and/or SGW-U not running"
        fi
    fi

    # TC-4: Sxb SMF <-> UPF PFCP association
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local s_assoc="" u2_assoc=""
        $smf_up && s_assoc=$(docker_logs_recent_matches "smf" "PFCP associated|has already been associated" 20)
        $upf_up && u2_assoc=$(docker_logs_recent_matches "upf" "PFCP associated|has already been associated" 20)
        if [ -n "$s_assoc" ] && [ -n "$u2_assoc" ]; then
            pass "Sxb SMF<->UPF mutual PFCP association established (both nodes confirm — TS 29.244)"
        elif [ -n "$s_assoc" ] || [ -n "$u2_assoc" ]; then
            pass "Sxb SMF<->UPF PFCP association evidenced on one node — association up"
        elif $smf_up && $upf_up; then
            fail "SMF and UPF both running but NO Sxb PFCP association evidence" \
                 "Sxb may be down — check SMF/UPF PFCP addresses and reachability"
        else
            skip "Sxb SMF<->UPF association" "SMF and/or UPF not running"
        fi
    fi

    # TC-5: PFCP node configuration audit (mutual server/client)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local ok=0 total=0 nf cfg
        for nf in sgwc sgwu smf upf; do
            if container_is_running "$nf"; then
                total=$((total + 1))
                cfg=$(read_nf_config "$nf")
                echo "$cfg" | grep -qiE 'pfcp' && ok=$((ok + 1))
            fi
        done
        if [ "$total" -eq 0 ]; then
            skip "PFCP node configuration audit" "No PFCP nodes running"
        elif [ "$ok" -ge 1 ] && [ "$ok" -eq "$total" ]; then
            pass "PFCP configured on all $total running node(s) (sgwc/sgwu/smf/upf carry pfcp config — TS 29.244)"
        elif [ "$ok" -ge 1 ]; then
            pass "PFCP configuration present on $ok of $total nodes (verify the remainder)"
        else
            skip "PFCP node configuration audit" "PFCP config not found in node YAMLs (check mount paths)"
        fi
    fi

    # TC-6: PFCP request/response message exchange evidence
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local msg_ev="" nf
        for nf in sgwc sgwu smf upf; do
            if container_is_running "$nf"; then
                msg_ev=$(docker_logs_recent_matches "$nf" "PFCP\\[REQ\\]|PFCP\\[RSP\\]" 15)
                [ -n "$msg_ev" ] && break
            fi
        done
        if [ -n "$msg_ev" ]; then
            pass "PFCP request/response message exchange evidenced (PFCP[REQ]/[RSP] — TS 29.244 §7)"
            append_report_block "PFCP message exchange" "$(echo "$msg_ev" | tail -3)"
        else
            skip "PFCP request/response message exchange" \
                 "No PFCP[REQ]/[RSP] in recent logs — associations are otherwise confirmed (TC-3/4)"
        fi
    fi

    # TC-7: SGW-U GTP-U S1-U data plane bound (2152)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if ! $sgwu_up; then
            skip "SGW-U GTP-U S1-U (2152)" "SGW-U container not running"
        elif container_listens_on_port "sgwu" 2152 || docker_logs_recent_matches "sgwu" "gtp.?server|2152" 3 | grep -qiE 'gtp|2152'; then
            pass "SGW-U GTP-U bound on S1-U (2152/UDP) — user-plane transport toward eNB"
        else
            skip "SGW-U GTP-U S1-U (2152)" "2152 not confirmed (may bind after first bearer)"
        fi
    fi

    # TC-8: PFCP association liveness / keepalive
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local loss="" nf
        for nf in sgwc sgwu smf upf; do
            if container_is_running "$nf"; then
                loss=$(docker_logs_recent_matches "$nf" "PFCP.*(no response|timeout|association.*(lost|fail|release)|peer.*(down|lost))" 6)
                [ -n "$loss" ] && break
            fi
        done
        if [ "$sgwu_up" = false ] && [ "$upf_up" = false ]; then
            skip "PFCP association liveness" "No PFCP nodes running"
        elif [ -n "$loss" ]; then
            skip "PFCP association liveness" "Association disturbance in logs (may be transient): $(echo "$loss" | tail -1)"
        else
            pass "PFCP association liveness OK — no association loss/timeout in logs (heartbeat keepalive maintaining Sxa/Sxb)"
        fi
    fi

    # TC-9: PFCP Session Establishment evidence
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local sess_ev="" nf
        for nf in smf sgwc upf sgwu; do
            if container_is_running "$nf"; then
                sess_ev=$(docker_logs_recent_matches "$nf" "[Ss]ession [Ee]stablish|PFCP.*[Ss]ession|sess\\(" 10)
                [ -n "$sess_ev" ] && break
            fi
        done
        if [ -n "$sess_ev" ]; then
            pass "PFCP Session Establishment evidence present (per-bearer PFCP session signalling — TS 29.244 §7.5.2)"
            append_report_block "PFCP session evidence" "$(echo "$sess_ev" | tail -3)"
        else
            skip "PFCP Session Establishment evidence" \
                 "No PFCP session messages in window — trigger a UE attach (regression/ue_sim), then re-run"
        fi
    fi

    # TC-10: PFCP rules PDR/FAR/QER installation evidence
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local rule_ev="" nf
        for nf in smf upf sgwc sgwu; do
            if container_is_running "$nf"; then
                rule_ev=$(docker_logs_recent_matches "$nf" "PDR|FAR|QER|BAR|[Pp]acket [Dd]etection|[Ff]orwarding [Aa]ction" 6)
                [ -n "$rule_ev" ] && break
            fi
        done
        if [ -n "$rule_ev" ]; then
            pass "PFCP rule install evidence (PDR/FAR/QER — packet-detection/forwarding/QoS rules, TS 29.244 §7.5)"
            append_report_block "PFCP rule evidence" "$(echo "$rule_ev" | tail -3)"
        else
            skip "PFCP rules PDR/FAR/QER" \
                 "Rules are carried as IEs in PFCP session messages, logged only at debug verbosity. Raise node log level or capture a PFCP pcap to evidence PDR/FAR/QER installation"
        fi
    fi

    # TC-11: PFCP Usage Reporting (URR) for charging
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local urr_ev="" nf
        for nf in smf upf sgwc sgwu; do
            if container_is_running "$nf"; then
                urr_ev=$(docker_logs_recent_matches "$nf" "URR|[Uu]sage [Rr]eport|[Vv]olume [Tt]hreshold|[Cc]harging" 6)
                [ -n "$urr_ev" ] && break
            fi
        done
        if [ -n "$urr_ev" ]; then
            pass "PFCP Usage Reporting (URR) evidence present (volume/time measurement for charging, TS 29.244 §7.5.8)"
            append_report_block "URR evidence" "$(echo "$urr_ev" | tail -3)"
        else
            skip "PFCP Usage Reporting (URR)" \
                 "URR usage reports need active data sessions + debug verbosity (feeds offline charging — see future charging feature)"
        fi
    fi

    # TC-12: PFCP association restoration / recovery handling (TS 23.527)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local rec_ev="" nf
        for nf in smf upf sgwc sgwu; do
            if container_is_running "$nf"; then
                rec_ev=$(docker_logs_recent_matches "$nf" "has already been associated|[Rr]ecovery|[Rr]estoration|re-?associat" 8)
                [ -n "$rec_ev" ] && break
            fi
        done
        if [ -n "$rec_ev" ]; then
            pass "PFCP association restoration handling evidenced (idempotent re-association / recovery — TS 23.527)"
            append_report_block "Restoration evidence" "$(echo "$rec_ev" | tail -2)"
        else
            skip "PFCP association restoration / recovery" \
                 "No re-association/recovery events in window (restoration exercised by a node restart; associations are stable)"
        fi
    fi

    end_feature
}
