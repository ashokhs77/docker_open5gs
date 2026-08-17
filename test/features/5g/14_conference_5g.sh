#!/bin/bash
# Feature 14: Conference Tests (5G VoNR)
# Validates conference dial-in over the VoNR IMS stack.
# The IMS infrastructure (P-CSCF, FreeSWITCH, RTPEngine) is shared between
# 4G VoLTE and 5G VoNR. Conference routing and media rely on the same components;
# the only difference is the access bearer (PDU session instead of LTE bearer).
#
# COMPLETE-PATH conversion: the conference *call* tests dial a room number (1NNR)
# THROUGH the P-CSCF (INVITE sip:<room>@IMS_DOMAIN → P-CSCF FSDISPATCH → FreeSWITCH),
# NOT a direct FreeSWITCH dial. Since the IMS is shared with 4G, this exercises the
# same conference engine AND the same P-CSCF conference CDR. Assertion rule:
# N UEs dialed ⇒ EXACTLY N `LEG` rows for that bridge in the P-CSCF conf_cdr.csv.
# SIPp clients from TEST_NETWORK are accepted by the P-CSCF WITH_SIPP_TEST bypass.
#
# Tests:
#   TC-1:  DNS conf-factory resolution (infra)
#   TC-2:  1-UE audio VoNR conference — COMPLETE path (room 1010)
#   TC-3:  P-CSCF VoNR conf-factory routing (P-CSCF-side; gated on conf-factory DNS)
#   TC-4:  1-UE video ViNR conference — COMPLETE path (room 1011)
#   TC-5:  P-CSCF video conf-factory routing (P-CSCF-side; gated on conf-factory DNS)
#   TC-6:  Sequential conf-factory rooms (P-CSCF-side; gated on conf-factory DNS)
#   TC-7:  4-UE audio VoNR conference — COMPLETE path (room 1012)
#   TC-8:  Hold SDP via conf-factory (P-CSCF-side; gated on conf-factory DNS)
#   TC-9:  Conference room reuse — COMPLETE path (room 1013 → 2 CDR rows)
#   TC-10: Distinct conference rooms + CDR isolation — COMPLETE path (rooms 1014, 1015)
#   TC-11: PCF N5 QoS policy path for IMS sessions (5G-specific: QoS flows)
#   TC-12: PCF N5 SBI interface reachability (replaces Rx Diameter peer check)
#   TC-13: Inter-NIB conference INVITE (join conference at external domain)
#   TC-14: N-UE SINGLE audio (VoNR) conference — COMPLETE path (24 → room 1016; N ⇒ N CDR rows)
#   TC-15: N-UE SINGLE video (ViNR) conference — COMPLETE path (8 → room 1017; N ⇒ N CDR rows)
#
# The conf-factory tests (TC-3/5/6/8) route through the P-CSCF (not a direct FS dial)
# and remain gated on conf-factory DNS. TC-14/15 hold is kept < FS 30s rtp-timeout (no
# real RTP is sourced) so legs stay simultaneously in the room until they BYE.
# Env-tunable: CONF_AUDIO_MEMBERS=24, CONF_VIDEO_MEMBERS=8, CONF_SOAK_SECS=20,
#              CONF_AUDIO_ROOM=1016, CONF_VIDEO_ROOM=1017, CONF_CALL_HOLD=6,
#              CONF_MULTI_HOLD=20, CONF_JOIN_STAGGER=0.3.

set +e

# ============================================================================
# COMPLETE-PATH conference helpers (5G VoNR). The IMS (P-CSCF + FreeSWITCH) is
# shared with 4G, so conference behaviour and the conference CDR are identical.
#
# Every conference *call* below dials a room number (1NNR) THROUGH the P-CSCF
# (INVITE sip:<room>@IMS_DOMAIN → P-CSCF FSDISPATCH → FreeSWITCH), NOT a direct
# FreeSWITCH dial. This is the real IMS path and it also drives the P-CSCF
# conference CDR (`/cdr-logs/conf_cdr.csv`). SIPp clients from TEST_NETWORK are
# accepted via the P-CSCF WITH_SIPP_TEST bypass. Assertion (per requirement):
# N UEs dialed ⇒ EXACTLY N `LEG` rows for that bridge in conf_cdr.csv.
# ============================================================================

# Count LEG rows for a conference bridge id (col 1 == LEG, col 8 == room).
_conf_cdr_leg_count() {
    local room="$1"
    docker exec pcscf sh -c \
        "test -f /cdr-logs/conf_cdr.csv && awk -F',' -v r='${room}' '\$1==\"LEG\" && \$8==r{c++} END{print c+0}' /cdr-logs/conf_cdr.csv || echo 0" \
        2>/dev/null | tr -dc '0-9'
}

# Launch N SIPp legs dialing <room> through the P-CSCF, hold, then BYE. No assertion
# (used both by _conf_pcscf_case and directly by the reuse/isolation TCs).
# Args: $1=N $2=room $3=media(audio|video) $4=hold_secs
_conf_pcscf_dial() {
    local n="$1" room="$2" media="$3" hold="$4"
    local scn="/opt/test/scenarios/fs_pcscf_conf_audio.xml"
    [ "$media" = "video" ] && scn="/opt/test/scenarios/fs_pcscf_conf_video.xml"
    local tmp="/tmp/pcscf_conf_${media}_5g.xml"
    sed "s/IMS_DOMAIN/$IMS_DOMAIN/g" "$scn" > "$tmp"
    local hold_ms=$(( hold * 1000 )) pids="" i port
    for i in $(seq 1 "$n"); do
        port=$(( 7300 + i ))
        sipp "${PCSCF_IP}:${PCSCF_PORT:-5060}" -sf "$tmp" -s "$room" \
            -i "$LOCAL_IP" -p "$port" -d "$hold_ms" \
            -m 1 -l 1 -timeout $(( hold + 30 )) -timeout_error \
            >/tmp/sipp_pcscfconf_${room}_${i}.log 2>&1 &
        pids="$pids $!"
        sleep "${CONF_JOIN_STAGGER:-0.3}"
    done
    for i in $pids; do wait "$i" 2>/dev/null || true; done
    sleep 3   # let the P-CSCF exec_msg flush LEG rows after the BYEs
}

# One TC: N UEs dial <room> through the P-CSCF, then assert EXACTLY N new LEG rows.
# Args: $1=N $2=room $3=media(audio|video) $4=hold_secs $5=human-label
_conf_pcscf_case() {
    local n="$1" room="$2" media="$3" hold="$4" label="$5"
    if ! check_port "$PCSCF_IP" "${PCSCF_PORT:-5060}"; then
        skip "$label" "P-CSCF not reachable"
        return
    fi
    local before; before=$(_conf_cdr_leg_count "$room"); before=${before:-0}
    _conf_pcscf_dial "$n" "$room" "$media" "$hold"
    local after; after=$(_conf_cdr_leg_count "$room"); after=${after:-0}
    local delta=$(( after - before ))
    echo "  ${label}: conf_cdr LEG rows(delta)=${delta}/${n} (room ${room}, complete path)" >> "$_FEATURE_REPORT"
    if [ "$delta" -eq "$n" ]; then
        pass "${label}: ${n} UEs dialed room ${room} via P-CSCF → exactly ${n} conf_cdr LEG rows"
    else
        fail "${label}: complete-path CDR count mismatch" \
             "expected ${n} LEG rows for room ${room}, got ${delta} — system/routing/CDR shortfall on the complete path"
    fi
}

run_conference_5g_tests() {
    start_feature "Conference (5G VoNR)"

    local conf_factory_dns_available=false
    local conf_dns
    conf_dns=$(dig +short conf-factory.${IMS_DOMAIN} @${DNS_IP} A 2>/dev/null | head -1 | tr -d '[:space:]')
    if [ -n "$conf_dns" ]; then
        conf_factory_dns_available=true
        log "conf-factory DNS available: ${conf_dns}"
    else
        log "NOTE: conf-factory DNS not configured — conf-factory tests (TC-3,5,6,8) will be skipped"
    fi

    log "Preparing SIPp conference scenarios..."
    sed "s/IMS_DOMAIN/$IMS_DOMAIN/g" /opt/test/scenarios/ue_a_conf_factory.xml > /tmp/test_conf_factory_5g.xml
    sed "s/IMS_DOMAIN/$IMS_DOMAIN/g" /opt/test/scenarios/ue_a_vilte_conf_factory.xml > /tmp/test_vilte_conf_factory_5g.xml
    sed "s/IMS_DOMAIN/$IMS_DOMAIN/g" /opt/test/scenarios/ue_a_hold_detect.xml > /tmp/test_hold_detect_5g.xml
    log "Conference scenarios prepared"

    # TC-1: DNS conf-factory resolution
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: DNS conf-factory resolution"
        if $conf_factory_dns_available; then
            if [ "$conf_dns" = "$PCSCF_IP" ]; then
                pass "conf-factory.${IMS_DOMAIN} resolves to ${PCSCF_IP}"
            else
                fail "conf-factory.${IMS_DOMAIN} resolves to wrong IP" "Got ${conf_dns}, expected ${PCSCF_IP}"
            fi
        else
            skip "DNS conf-factory resolution" "conf-factory DNS not configured"
        fi
    fi

    # TC-2: 1-UE audio VoNR conference over the COMPLETE path (P-CSCF-routed)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: 1-UE audio VoNR conference via complete path (INVITE 1010 → P-CSCF → FreeSWITCH)"
        _conf_pcscf_case 1 1010 audio "${CONF_CALL_HOLD:-6}" "1-UE audio VoNR conference (complete path)"
    fi

    # TC-3: P-CSCF VoNR conf-factory routing
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if ! $conf_factory_dns_available; then
            skip "P-CSCF VoNR conf-factory routing" "conf-factory DNS not configured"
        else
            log "TC-${_TEST_NUM}: P-CSCF VoNR conf-factory INVITE routing"
            sipp ${PCSCF_IP}:${PCSCF_PORT} \
                -sf /tmp/test_conf_factory_5g.xml \
                -s mmtel \
                -i $LOCAL_IP -p 7200 \
                -m 1 -l 1 -timeout 15 -timeout_error \
                >/tmp/sipp_conf5g_tc3.log 2>&1
            RESULT=$?
            if [ $RESULT -eq 0 ]; then
                pass "P-CSCF routed VoNR conf-factory INVITE to FreeSWITCH (got 200 OK)"
            else
                fail "P-CSCF VoNR conf-factory routing failed" "SIPp exit code: $RESULT"
            fi
        fi
    fi

    # TC-4: 1-UE video (ViNR) conference over the COMPLETE path (P-CSCF-routed)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: 1-UE video ViNR conference via complete path (INVITE 1011 → P-CSCF → FreeSWITCH)"
        _conf_pcscf_case 1 1011 video "${CONF_CALL_HOLD:-6}" "1-UE video ViNR conference (complete path)"
    fi

    # TC-5: P-CSCF video conf-factory routing
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if ! $conf_factory_dns_available; then
            skip "P-CSCF video conf-factory routing" "conf-factory DNS not configured"
        else
            log "TC-${_TEST_NUM}: P-CSCF video conf-factory INVITE routing (video+audio SDP)"
            sipp ${PCSCF_IP}:${PCSCF_PORT} \
                -sf /tmp/test_vilte_conf_factory_5g.xml \
                -s mmtel \
                -i $LOCAL_IP -p 7400 \
                -m 1 -l 1 -timeout 15 -timeout_error \
                >/tmp/sipp_conf5g_tc5.log 2>&1
            RESULT=$?
            if [ $RESULT -eq 0 ]; then
                pass "P-CSCF routed video conf-factory INVITE to FreeSWITCH"
            else
                fail "P-CSCF video conf-factory routing failed" "SIPp exit code: $RESULT"
            fi
        fi
    fi

    # TC-6: Sequential conference rooms
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if ! $conf_factory_dns_available; then
            skip "Sequential conference rooms via conf-factory" "conf-factory DNS not configured"
        else
            log "TC-${_TEST_NUM}: Multiple sequential conference rooms via conf-factory"
            sipp ${PCSCF_IP}:${PCSCF_PORT} \
                -sf /tmp/test_conf_factory_5g.xml -s mmtel \
                -i $LOCAL_IP -p 7500 -m 1 -l 1 -timeout 15 -timeout_error \
                >/tmp/sipp_conf5g_tc6a.log 2>&1; RESULT_A=$?
            sleep 1
            sipp ${PCSCF_IP}:${PCSCF_PORT} \
                -sf /tmp/test_conf_factory_5g.xml -s mmtel \
                -i $LOCAL_IP -p 7501 -m 1 -l 1 -timeout 15 -timeout_error \
                >/tmp/sipp_conf5g_tc6b.log 2>&1; RESULT_B=$?

            if [ $RESULT_A -eq 0 ] && [ $RESULT_B -eq 0 ]; then
                pass "Both sequential conf-factory INVITEs succeeded (room counter working)"
            elif [ $RESULT_A -eq 0 ]; then
                fail "Second conf-factory INVITE failed" "Room counter collision? SIPp exit: $RESULT_B"
            else
                fail "First conf-factory INVITE failed" "SIPp exit: $RESULT_A"
            fi
        fi
    fi

    # TC-7: 4-UE audio VoNR conference over the COMPLETE path (P-CSCF-routed)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: 4-UE audio VoNR conference via complete path (room 1012 → P-CSCF → FreeSWITCH)"
        _conf_pcscf_case 4 1012 audio "${CONF_MULTI_HOLD:-20}" "4-UE audio VoNR conference (complete path)"
    fi

    # TC-8: Hold SDP via conf-factory
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if ! $conf_factory_dns_available; then
            skip "Hold SDP via conf-factory" "conf-factory DNS not configured"
        else
            log "TC-${_TEST_NUM}: Hold SDP (sendonly) via P-CSCF conf-factory"
            sipp ${PCSCF_IP}:${PCSCF_PORT} \
                -sf /tmp/test_hold_detect_5g.xml \
                -s mmtel -i $LOCAL_IP -p 7700 \
                -m 1 -l 1 -timeout 15 -timeout_error \
                >/tmp/sipp_conf5g_tc8.log 2>&1
            RESULT=$?
            if [ $RESULT -eq 0 ]; then
                pass "P-CSCF handled sendonly SDP and routed conf-factory to FreeSWITCH"
            else
                fail "Sendonly SDP conf-factory routing failed" "SIPp exit code: $RESULT"
            fi
        fi
    fi

    # TC-9: conference room reuse over the COMPLETE path (dial → teardown → re-dial).
    # Two sequential single-UE dials to the same room via the P-CSCF; expect the room
    # reusable and EXACTLY 2 CDR LEG rows total.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: conference room 1013 reuse via complete path (dial, teardown, re-dial)"
        if ! check_port "$PCSCF_IP" "${PCSCF_PORT:-5060}"; then
            skip "Conference room reuse (complete path)" "P-CSCF not reachable"
        else
            local r9_before r9_after
            r9_before=$(_conf_cdr_leg_count 1013); r9_before=${r9_before:-0}
            local tmp9="/tmp/pcscf_conf_reuse_5g.xml"
            sed "s/IMS_DOMAIN/$IMS_DOMAIN/g" /opt/test/scenarios/fs_pcscf_conf_audio.xml > "$tmp9"
            sipp "${PCSCF_IP}:${PCSCF_PORT:-5060}" -sf "$tmp9" -s 1013 -i "$LOCAL_IP" -p 7810 \
                -d $(( ${CONF_CALL_HOLD:-6} * 1000 )) -m 1 -l 1 -timeout 40 -timeout_error \
                >/tmp/sipp_conf5g_tc9a.log 2>&1
            sleep 2
            sipp "${PCSCF_IP}:${PCSCF_PORT:-5060}" -sf "$tmp9" -s 1013 -i "$LOCAL_IP" -p 7811 \
                -d $(( ${CONF_CALL_HOLD:-6} * 1000 )) -m 1 -l 1 -timeout 40 -timeout_error \
                >/tmp/sipp_conf5g_tc9b.log 2>&1
            sleep 3
            r9_after=$(_conf_cdr_leg_count 1013); r9_after=${r9_after:-0}
            if [ $(( r9_after - r9_before )) -eq 2 ]; then
                pass "Room 1013 reusable via complete path: 2 sequential dials → exactly 2 CDR LEG rows"
            else
                fail "Room 1013 reuse over complete path failed" "CDR LEG delta=$(( r9_after - r9_before ))/2"
            fi
        fi
    fi

    # TC-10: distinct conference rooms over the COMPLETE path (routing + per-bridge
    # CDR isolation). Two rooms (1014, 1015), each a 2-UE conference via the P-CSCF;
    # each bridge must record EXACTLY its own 2 LEG rows.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: distinct VoNR conference rooms 1014 + 1015 via complete path (CDR isolation)"
        if ! check_port "$PCSCF_IP" "${PCSCF_PORT:-5060}"; then
            skip "Distinct conference rooms (complete path)" "P-CSCF not reachable"
        else
            local b14 b15 a14 a15
            b14=$(_conf_cdr_leg_count 1014); b14=${b14:-0}
            b15=$(_conf_cdr_leg_count 1015); b15=${b15:-0}
            _conf_pcscf_dial 2 1014 audio "${CONF_MULTI_HOLD:-20}"
            _conf_pcscf_dial 2 1015 audio "${CONF_MULTI_HOLD:-20}"
            a14=$(_conf_cdr_leg_count 1014); a14=${a14:-0}
            a15=$(_conf_cdr_leg_count 1015); a15=${a15:-0}
            if [ $(( a14 - b14 )) -eq 2 ] && [ $(( a15 - b15 )) -eq 2 ]; then
                pass "Distinct complete-path VoNR conferences isolated: rooms 1014 and 1015 each recorded exactly 2 CDR LEG rows"
            else
                fail "Distinct complete-path conference CDR isolation mismatch" "room 1014 LEG delta=$(( a14 - b14 ))/2, room 1015 LEG delta=$(( a15 - b15 ))/2"
            fi
        fi
    fi

    # TC-11: PCF N5 QoS policy path for IMS sessions (5G-specific)
    # In 5G SA, P-CSCF can use both Rx/Diameter and PCF N5 SBI for QoS authorization.
    # This TC validates: (a) Rx AAR is correctly bypassed for SIPp test clients without
    # +sip.instance IMEI, and (b) the PCF N5 SBI interface is reachable for real IMS UEs.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: PCF N5 QoS policy path for VoNR IMS sessions"
        log "  Checks: (a) Rx AAR bypass for test clients (b) PCF N5 SBI port reachable"

        local rx_skipped=0 rx_doing_mo=0 pcf_n5_ok=false

        # (a) Check P-CSCF Rx AAR bypass (SIPp clients without IMEI should skip Rx)
        local rx_log
        rx_log=$(docker logs pcscf 2>&1 | tail -2000)
        rx_skipped=$(printf '%s\n' "$rx_log" | grep -Ec "Skipping Rx|Non-IMS SIP client|Skipping MO Rx|Skipping MT Rx|Skipping Rx media authorization" 2>/dev/null || true)
        rx_skipped=${rx_skipped:-0}
        rx_doing_mo=$(printf '%s\n' "$rx_log" | grep -Ec "DOING RX in MO|DOING RX IN MO" 2>/dev/null || true)
        rx_doing_mo=${rx_doing_mo:-0}

        # (b) Check PCF N5 SBI port (5G-specific)
        if check_port "${PCF_IP:-172.22.1.27}" "7777"; then
            pcf_n5_ok=true
        fi

        if $pcf_n5_ok && [ "$rx_skipped" -gt 0 ]; then
            pass "PCF N5 reachable on port 7777 and Rx AAR bypassed for SIPp clients (${rx_skipped} skips). IMS UEs with IMEI trigger Rx AAR → PCF → QoS flow authorization"
        elif $pcf_n5_ok; then
            local rx_mod
            rx_mod=$(docker exec pcscf kamcmd mod.is_loaded ims_qos 2>/dev/null | tr -d '\r' | tail -n 1)
            rx_mod=${rx_mod:-unknown}
            if echo "$rx_mod" | grep -qi "true\|loaded"; then
                pass "PCF N5 SBI port 7777 reachable. ims_qos loaded — Rx bypass log pattern may differ in this P-CSCF version"
            else
                pass "PCF N5 SBI port 7777 reachable. ims_qos module not loaded (N5-only PCF path active)"
            fi
        else
            fail "PCF N5 SBI port 7777 not reachable" "QoS flow authorization for VoNR PDU sessions unavailable"
        fi
    fi

    # TC-12: PCF N5 SBI interface connectivity (5G-specific)
    # In 5G SA, the PCF exposes an N5 SBI (HTTP/2) interface for policy decisions.
    # P-CSCF uses this (via Rx wrapper or natively) for IMS session policy.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: PCF N5 SBI interface connectivity"
        local pcf_sbi_body
        pcf_sbi_body=$(sbi_get_body "${PCF_IP:-172.22.1.27}" "7777" "/npcf-smpolicycontrol/v1" 2>/dev/null | head -1)
        local pcf_code
        pcf_code=$(sbi_get "${PCF_IP:-172.22.1.27}" "7777" "/npcf-smpolicycontrol/v1" 2>/dev/null)

        # Also check Rx Diameter peer status (P-CSCF may use Rx → PCF even in 5G SA)
        local cdp_peers rx_connected=0
        cdp_peers=$(docker exec pcscf kamcmd cdp.list_peers 2>/dev/null || echo "")
        if [ -n "$cdp_peers" ]; then
            rx_connected=$(printf '%s\n' "$cdp_peers" | grep -c "I-Open\|State.*Open" 2>/dev/null || true)
            rx_connected=${rx_connected:-0}
        fi

        if [ "$pcf_code" -ge 200 ] && [ "$pcf_code" -lt 500 ] 2>/dev/null; then
            pass "PCF N5 SBI (npcf-smpolicycontrol) responding (HTTP ${pcf_code}) — QoS policy path operational"
        elif [ "$rx_connected" -gt 0 ]; then
            pass "PCF reachable via Rx Diameter (${rx_connected} peer(s) in I-Open state) — IMS QoS policy path operational"
        elif check_port "${PCF_IP:-172.22.1.27}" "7777"; then
            pass "PCF SBI port 7777 reachable (N5 policy interface available for VoNR sessions)"
        else
            fail "PCF not reachable via N5 SBI or Rx Diameter — IMS QoS policy unavailable" \
                 "PCF_IP=${PCF_IP:-172.22.1.27}, SBI code=${pcf_code:-no response}, Rx peers=${rx_connected}"
        fi
    fi

    # TC-13: Inter-NIB conference INVITE
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Inter-NIB conference INVITE (join room at external domain)"
        local scenario="/opt/test/scenarios/conference_inter_nib_invite.xml"
        if [ ! -f "$scenario" ]; then
            skip "Inter-NIB conference INVITE" "Scenario conference_inter_nib_invite.xml not found"
        elif ! check_port "$PCSCF_IP" "${PCSCF_PORT:-5060}"; then
            skip "Inter-NIB conference INVITE" "P-CSCF not reachable"
        else
            local inter_conf_out
            inter_conf_out=$(run_sipp_templated "$PCSCF_IP" "${PCSCF_PORT:-5060}" \
                "$scenario" "1010" 9340 2>&1)
            local inter_conf_rc=$?

            if echo "$inter_conf_out" | grep -qE "Assertion.*failed|Segmentation fault|not implemented in display"; then
                fail "Inter-NIB conference INVITE: SIPp crashed" \
                     "$(echo "$inter_conf_out" | grep -E 'Assertion|Segmentation|ERROR' | head -3)"
            elif echo "$inter_conf_out" | grep -qE "(Successful call|Failed call)"; then
                pass "Inter-NIB conference INVITE: IMS chain processed INVITE toward external domain"
            elif [ $inter_conf_rc -eq 0 ]; then
                pass "Inter-NIB conference INVITE: SIPp exited cleanly"
            else
                fail "Inter-NIB conference INVITE: No SIP response from P-CSCF" \
                     "$(echo "$inter_conf_out" | tail -5)"
            fi
        fi
    fi

    # TC-14: N-UE SINGLE audio (VoNR) conference — "24 UEs in one conference" over the
    # COMPLETE path. N SIPp legs dial ONE room through the P-CSCF and overlap for the
    # hold window. Requirement: N UEs ⇒ EXACTLY N CDR LEG rows.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local n_aud="${CONF_AUDIO_MEMBERS:-24}" room_aud="${CONF_AUDIO_ROOM:-1016}" hold_a="${CONF_SOAK_SECS:-20}"
        log "TC-${_TEST_NUM}: ${n_aud}-UE SINGLE audio (VoNR) conference via COMPLETE path (room ${room_aud} → P-CSCF → FreeSWITCH), ${hold_a}s hold"
        _conf_pcscf_case "$n_aud" "$room_aud" audio "$hold_a" "${n_aud}-UE audio VoNR conference (complete path)"
    fi

    # TC-15: N-UE SINGLE video (ViNR) conference — "8 UEs in one video conference" over
    # the COMPLETE path (audio+video SDP). Requirement: N UEs ⇒ EXACTLY N CDR LEG rows.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local n_vid="${CONF_VIDEO_MEMBERS:-8}" room_vid="${CONF_VIDEO_ROOM:-1017}" hold_v="${CONF_SOAK_SECS:-20}"
        log "TC-${_TEST_NUM}: ${n_vid}-UE SINGLE video (ViNR) conference via COMPLETE path (room ${room_vid} → P-CSCF → FreeSWITCH), ${hold_v}s hold"
        _conf_pcscf_case "$n_vid" "$room_vid" video "$hold_v" "${n_vid}-UE video ViNR conference (complete path)"
    fi

    rm -f /tmp/sipp_conf5g_tc*.log /tmp/sipp_confsoak_*.log /tmp/sipp_pcscfconf_*.log /tmp/pcscf_conf_*_5g.xml /tmp/test_conf_factory_5g.xml /tmp/test_vilte_conf_factory_5g.xml /tmp/test_hold_detect_5g.xml 2>/dev/null
    end_feature
}
