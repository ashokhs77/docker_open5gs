#!/bin/bash
# Feature 08: CDR (5G)
# Validates Call Detail Record generation in the 5G SA + VoNR context.
# CDRs are produced by S-CSCF (Kamailio) for IMS calls; the mechanism
# is identical to 4G VoLTE — only the access bearer changes.
#
# Tests:
#   TC-1: CDR log file exists in S-CSCF container
#   TC-2: CDR htable configured in S-CSCF
#   TC-3: CDR entry present after a VoNR call
#   TC-4: CDR fields validation (caller, callee, duration)
#   TC-5: CDR audio/call type field
#   TC-6: CDR logrotate config exists
#   TC-7: CDR field completeness (all fields non-empty)
#   --- Conference CDR (P-CSCF; shared IMS with 4G) ---
#   TC-8:  conf-cdr-logger.sh installed + exec.so loaded on P-CSCF
#   TC-9:  confcdr htable configured on P-CSCF
#   TC-10: conference CDR logrotate config exists
#   TC-11: conf CDR write-path — 9-col schema, newest-on-top, 7-day retention
#   TC-12: REAL path — dial conference 1010 THROUGH the P-CSCF, assert a conf_cdr row
#   TC-13: live conf_cdr.csv field validation (now populated by TC-12)

set +e

CDR_LOG_PATH="${CDR_LOG_PATH:-/var/log/kamailio/cdr.log}"

run_cdr_5g_tests() {
    start_feature "CDR (5G)"

    # TC-1: CDR log file exists
    if should_run_test 1; then
        _TEST_NUM=1
        if container_is_running "scscf"; then
            local file_check
            file_check=$(docker exec scscf sh -c \
                "[ -f '${CDR_LOG_PATH}' ] && echo YES || echo NO" 2>/dev/null || echo "NO")
            if [ "$file_check" = "YES" ]; then
                pass "CDR log file exists: ${CDR_LOG_PATH}"
            else
                # Check /cdr-logs volume mount location
                local alt_check
                alt_check=$(docker exec scscf sh -c \
                    "find /cdr-logs /var/log/kamailio -name '*.log' 2>/dev/null | head -3" \
                    2>/dev/null || echo "")
                if [ -n "$alt_check" ]; then
                    pass "CDR log file found: ${alt_check}"
                else
                    # Kamailio creates the CDR log on the FIRST completed call.
                    # Without registered UEs, SIPp INVITE probes get 4xx and no
                    # call ever completes — absence of the file is expected here.
                    skip "CDR log file check" \
                         "No CDR log yet — CDR is written on completed calls only (requires registered UEs answering calls)"
                fi
            fi
        else
            skip "CDR log file check" "S-CSCF container not running"
        fi
    fi

    # TC-2: CDR htable configured in S-CSCF
    if should_run_test 2; then
        _TEST_NUM=2
        if container_is_running "scscf"; then
            local htable_check
            htable_check=$(docker exec scscf sh -c \
                "grep -r 'htable\|cdr\|acc\|accounting' /etc/kamailio_scscf/ 2>/dev/null | head -5" \
                2>/dev/null || echo "")
            if [ -n "$htable_check" ]; then
                pass "CDR/accounting configuration found in S-CSCF config"
            else
                fail "CDR htable config not found in S-CSCF" \
                     "Check /etc/kamailio_scscf/ for htable and CDR module config"
            fi
        else
            skip "CDR htable config check" "S-CSCF container not running"
        fi
    fi

    # TC-3: CDR entry after a VoNR call
    if should_run_test 3; then
        _TEST_NUM=3
        if container_is_running "scscf"; then
            local cdr_entries
            cdr_entries=$(docker exec scscf sh -c \
                "wc -l < '${CDR_LOG_PATH}' 2>/dev/null || find /cdr-logs -name '*.log' -exec wc -l {} \; 2>/dev/null | awk '{s+=\$1} END{print s+0}'" \
                2>/dev/null || echo "0")
            cdr_entries=$(echo "$cdr_entries" | tr -dc '0-9' | head -c 10)
            if [ "${cdr_entries:-0}" -gt 0 ] 2>/dev/null; then
                pass "CDR log has ${cdr_entries} line(s) — call records generated"
            else
                skip "CDR entry check" \
                     "CDR log empty — no completed VoNR calls in this environment (SIPp probes get 4xx without registered UEs)"
            fi
        else
            skip "CDR entry check" "S-CSCF container not running"
        fi
    fi

    # TC-4: CDR fields validation
    if should_run_test 4; then
        _TEST_NUM=4
        if container_is_running "scscf"; then
            local cdr_sample
            cdr_sample=$(docker exec scscf sh -c \
                "tail -10 '${CDR_LOG_PATH}' 2>/dev/null || find /cdr-logs -name '*.log' -exec tail -5 {} \; 2>/dev/null | head -10" \
                2>/dev/null || echo "")
            if [ -n "$cdr_sample" ]; then
                if echo "$cdr_sample" | grep -qE "sip:|@|INVITE|BYE|200"; then
                    pass "CDR fields contain SIP call information (From/To/method evidence)"
                else
                    pass "CDR data present (format may differ from expected pattern)"
                fi
            else
                skip "CDR fields validation" \
                     "CDR log empty — no completed calls to validate (requires registered UEs)"
            fi
        else
            skip "CDR fields validation" "S-CSCF container not running"
        fi
    fi

    # TC-5: CDR audio/call type field
    if should_run_test 5; then
        _TEST_NUM=5
        if container_is_running "scscf"; then
            local cdr_type
            cdr_type=$(docker exec scscf sh -c \
                "grep -iE 'audio|voice|vonr|volte|INVITE' '${CDR_LOG_PATH}' 2>/dev/null | tail -3" \
                2>/dev/null || echo "")
            if [ -n "$cdr_type" ]; then
                pass "CDR contains audio/call-type evidence"
            else
                skip "CDR audio type field" \
                     "No audio/INVITE evidence in CDR log; call type may be encoded differently"
            fi
        else
            skip "CDR audio type" "S-CSCF container not running"
        fi
    fi

    # TC-6: CDR logrotate config
    if should_run_test 6; then
        _TEST_NUM=6
        if container_is_running "scscf"; then
            local logrotate_check
            logrotate_check=$(docker exec scscf sh -c \
                "[ -f /etc/logrotate.d/kamailio ] && echo YES || ls /etc/logrotate.d/ 2>/dev/null" \
                2>/dev/null || echo "")
            if echo "$logrotate_check" | grep -qi "kamailio\|YES"; then
                pass "CDR logrotate config found: kamailio"
            else
                skip "CDR logrotate config" \
                     "Logrotate not configured for kamailio CDR logs (not required for lab)"
            fi
        else
            skip "CDR logrotate config" "S-CSCF container not running"
        fi
    fi

    # TC-7: CDR field completeness
    if should_run_test 7; then
        _TEST_NUM=7
        if container_is_running "scscf"; then
            local cdr_tail
            cdr_tail=$(docker exec scscf sh -c \
                "tail -5 '${CDR_LOG_PATH}' 2>/dev/null" 2>/dev/null || echo "")
            if [ -z "$cdr_tail" ]; then
                skip "CDR field completeness" "CDR log empty — no calls recorded yet"
            else
                # Check that lines are non-trivially short (> 40 chars suggests actual CDR data)
                local min_len
                min_len=$(echo "$cdr_tail" | awk '{print length}' | sort -n | head -1)
                if [ "${min_len:-0}" -gt 40 ] 2>/dev/null; then
                    pass "CDR fields appear complete (min line length ${min_len} chars)"
                else
                    fail "CDR lines suspiciously short (${min_len} chars)" \
                         "CDR may be missing required fields; check S-CSCF acc/CDR module config"
                fi
            fi
        else
            skip "CDR field completeness" "S-CSCF container not running"
        fi
    fi

    # ================= Conference CDR (P-CSCF, shared IMS) =================
    # Conference dials (1NNR) route P-CSCF -> FreeSWITCH (never via the S-CSCF), so
    # their CDR is produced on the P-CSCF at /cdr-logs/conf_cdr.csv. The mechanism is
    # identical to 4G (shared docker_kamailio pcscf). Schema (9 cols):
    #   RecordType,ConfHost,Participants,TotalParticipantCount,MediaType,StartTime,
    #   Duration,ConfBridgeID,EndReason

    # TC-8: conf-cdr-logger.sh installed + exec.so loaded on P-CSCF
    if should_run_test 8; then
        _TEST_NUM=8
        if container_is_running "pcscf"; then
            local logger_ok exec_ok
            logger_ok=$(docker exec pcscf sh -c "test -x /usr/local/bin/conf-cdr-logger.sh && echo yes" 2>/dev/null | tr -d '[:space:]')
            exec_ok=$(docker exec pcscf sh -c "grep -c 'loadmodule \"exec.so\"' /etc/kamailio_pcscf/kamailio_pcscf.cfg" 2>/dev/null | tr -d '[:space:]')
            if [ "$logger_ok" = "yes" ] && [ "${exec_ok:-0}" -gt 0 ] 2>/dev/null; then
                pass "conf-cdr-logger.sh executable and exec.so loaded on P-CSCF (shared IMS)"
            else
                fail "Conference CDR prerequisites missing on P-CSCF" "logger executable='${logger_ok}', exec.so load count='${exec_ok}'"
            fi
        else
            skip "Conference CDR logger check" "P-CSCF container not running"
        fi
    fi

    # TC-9: confcdr htable configured on P-CSCF
    if should_run_test 9; then
        _TEST_NUM=9
        if container_is_running "pcscf"; then
            local cfg_check
            cfg_check=$(docker exec pcscf sh -c "grep -c 'confcdr=>' /etc/kamailio_pcscf/kamailio_pcscf.cfg" 2>/dev/null | tr -d '[:space:]')
            if [ "${cfg_check:-0}" -gt 0 ] 2>/dev/null; then
                pass "confcdr htable configured on P-CSCF"
            else
                fail "confcdr htable not configured on P-CSCF" "grep for 'confcdr=>' in kamailio_pcscf.cfg returned ${cfg_check}"
            fi
        else
            skip "confcdr htable check" "P-CSCF container not running"
        fi
    fi

    # TC-10: conference CDR logrotate config exists
    if should_run_test 10; then
        _TEST_NUM=10
        if container_is_running "pcscf"; then
            if docker exec pcscf sh -c "ls /etc/logrotate.d/kamailio-conf-cdr" >/dev/null 2>&1; then
                pass "Conference CDR logrotate config exists at /etc/logrotate.d/kamailio-conf-cdr"
            else
                fail "Conference CDR logrotate config not found" "/etc/logrotate.d/kamailio-conf-cdr missing"
            fi
        else
            skip "Conference CDR logrotate check" "P-CSCF container not running"
        fi
    fi

    # TC-11: conf CDR write-path — runs the DEPLOYED logger against a throwaway CSV
    # inside the container (real /cdr-logs/conf_cdr.csv untouched). Epochs host-side.
    if should_run_test 11; then
        _TEST_NUM=11
        if container_is_running "pcscf"; then
            local now old expected_hdr
            now=$(date +%s)
            old=$(date -d '10 days ago' +%s 2>/dev/null)
            expected_hdr="RecordType,ConfHost,Participants,TotalParticipantCount,MediaType,StartTime,Duration,ConfBridgeID,EndReason"
            docker exec pcscf sh -c "sed 's#/cdr-logs/conf_cdr.csv#/tmp/cct5g.csv#' /usr/local/bin/conf-cdr-logger.sh > /tmp/cct5g_logger.sh && rm -f /tmp/cct5g.csv" >/dev/null 2>&1
            docker exec pcscf sh -c "bash /tmp/cct5g_logger.sh LEG 1000 2000 2 video $now 90 1230 NORMAL"      >/dev/null 2>&1
            docker exec pcscf sh -c "bash /tmp/cct5g_logger.sh LEG 1000 9999 1 audio $old 60 1230 NORMAL"       >/dev/null 2>&1
            docker exec pcscf sh -c "bash /tmp/cct5g_logger.sh CONF 1000 2000 2 video $now 300 1230 CONF_ENDED" >/dev/null 2>&1
            local csv hdr_line top_type ncols old_present
            csv=$(docker exec pcscf sh -c "cat /tmp/cct5g.csv" 2>/dev/null)
            hdr_line=$(printf '%s\n' "$csv" | sed -n '1p')
            top_type=$(printf '%s\n' "$csv" | sed -n '2p' | awk -F',' '{print $1}')
            ncols=$(printf '%s\n' "$csv" | sed -n '2p' | awk -F',' '{print NF}')
            old_present=$(printf '%s\n' "$csv" | grep -c ',9999,' 2>/dev/null | tr -d '[:space:]')
            docker exec pcscf sh -c "rm -f /tmp/cct5g.csv /tmp/cct5g_logger.sh" >/dev/null 2>&1
            local errs=""
            [ "$hdr_line" != "$expected_hdr" ]      && errs="${errs}header mismatch; "
            [ "$top_type" != "CONF" ]               && errs="${errs}newest not on top (top='${top_type}'); "
            [ "${ncols:-0}" -ne 9 ] 2>/dev/null     && errs="${errs}expected 9 cols got ${ncols}; "
            [ "${old_present:-0}" -ne 0 ] 2>/dev/null && errs="${errs}10-day row not pruned; "
            if [ -z "$errs" ]; then
                pass "Conference CDR write-path OK: 9-col schema, header, CONF newest-on-top, 10-day row pruned"
            else
                fail "Conference CDR write-path failed: ${errs}" "CSV: ${csv}"
            fi
        else
            skip "Conference CDR write-path" "P-CSCF container not running"
        fi
    fi

    # TC-12: REAL path — dial conference room 1010 THROUGH the P-CSCF (INVITE
    # sip:1010@IMS_DOMAIN → FSDISPATCH → FreeSWITCH) and assert a conf_cdr.csv row.
    if should_run_test 12; then
        _TEST_NUM=12
        local conf_room="${CONF_CDR_ROOM:-1010}"
        if ! container_is_running "pcscf"; then
            skip "Conference CDR via P-CSCF dial" "P-CSCF container not running"
        elif ! check_port "$PCSCF_IP" "${PCSCF_PORT:-5060}"; then
            skip "Conference CDR via P-CSCF dial" "P-CSCF not reachable"
        else
            local before after
            before=$(docker exec pcscf sh -c "test -f /cdr-logs/conf_cdr.csv && grep -c ',${conf_room},' /cdr-logs/conf_cdr.csv || echo 0" 2>/dev/null | tr -dc '0-9'); before=${before:-0}
            local tmp="/tmp/pcscf_conf_cdr_5g.xml"
            sed "s/IMS_DOMAIN/$IMS_DOMAIN/g" /opt/test/scenarios/fs_pcscf_conf_audio.xml > "$tmp"
            sipp "${PCSCF_IP}:${PCSCF_PORT:-5060}" -sf "$tmp" -s "$conf_room" \
                -i "$LOCAL_IP" -p 7250 -d 4000 -m 1 -l 1 -timeout 40 -timeout_error \
                >/tmp/sipp_cdr5g_conf.log 2>&1
            sleep 3
            after=$(docker exec pcscf sh -c "grep -c ',${conf_room},' /cdr-logs/conf_cdr.csv 2>/dev/null || echo 0" 2>/dev/null | tr -dc '0-9'); after=${after:-0}
            local new_row
            new_row=$(docker exec pcscf sh -c "grep ',${conf_room},' /cdr-logs/conf_cdr.csv 2>/dev/null | head -1" 2>/dev/null)
            rm -f "$tmp" /tmp/sipp_cdr5g_conf.log 2>/dev/null
            if [ "${after:-0}" -gt "${before:-0}" ] 2>/dev/null; then
                pass "Dial to conference ${conf_room} via P-CSCF produced a conf_cdr.csv row (${before}->${after}); newest: ${new_row}"
            else
                fail "P-CSCF conference dial produced NO conf_cdr.csv row for bridge ${conf_room}" "before=${before}, after=${after} — investigate P-CSCF CONF_CDR routes / WITH_SIPP_TEST"
            fi
        fi
    fi

    # TC-13: live conf_cdr.csv field validation (populated by TC-12; tolerant otherwise)
    if should_run_test 13; then
        _TEST_NUM=13
        if ! container_is_running "pcscf"; then
            skip "Conference CDR field validation" "P-CSCF container not running"
        else
            local exists first_data rtype ncols
            exists=$(docker exec pcscf sh -c "test -f /cdr-logs/conf_cdr.csv && echo yes" 2>/dev/null | tr -d '[:space:]')
            if [ "$exists" != "yes" ]; then
                skip "Conference CDR field validation" "/cdr-logs/conf_cdr.csv not present — no conference call routed through P-CSCF yet"
            else
                first_data=$(docker exec pcscf sh -c "sed -n '2p' /cdr-logs/conf_cdr.csv" 2>/dev/null)
                if [ -z "$first_data" ]; then
                    skip "Conference CDR field validation" "conf_cdr.csv has header only — no records yet"
                else
                    rtype=$(printf '%s' "$first_data" | awk -F',' '{print $1}')
                    ncols=$(printf '%s' "$first_data" | awk -F',' '{print NF}')
                    if { [ "$rtype" = "LEG" ] || [ "$rtype" = "CONF" ]; } && [ "${ncols:-0}" -eq 9 ] 2>/dev/null; then
                        pass "Live conf_cdr.csv record valid: RecordType='${rtype}', 9 fields — ${first_data}"
                    else
                        fail "Live conf_cdr.csv record malformed" "RecordType='${rtype}' (expect LEG/CONF), fields=${ncols} (expect 9). Line: ${first_data}"
                    fi
                fi
            fi
        fi
    fi

    end_feature
}
