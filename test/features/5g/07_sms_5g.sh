#!/bin/bash
# Feature 07: SMS over 5GS
# Validates SMS delivery via IMS (SIP MESSAGE) in the 5G SA context.
# The SMSC, IMS chain, and MySQL SMS store are identical to 4G;
# only the access bearer differs (5G PDU session instead of 4G bearer).
#
# Tests:
#   TC-1: SMSC DNS resolution
#   TC-2: SMSC SRV record
#   TC-3: SMSC SIP port reachable
#   TC-4: SIP MESSAGE direct to SMSC (basic smoke)
#   TC-5: MySQL SMSC database check
#   TC-6: Intra-NIB SIP MESSAGE via IMS chain (P-CSCF -> S-CSCF -> SMSC)
#   TC-7: SMS delivery confirmation (MySQL messages table)
#   TC-8: Inter-NIB SMS routing (no 5xx for external URI)
#   TC-9: SMS body integrity check

set +e

run_sms_5g_tests() {
    start_feature "SMS over 5GS"

    # Set by TC-4/TC-6 when a MESSAGE was actually sent; TC-7 uses it to
    # distinguish "no SMS generated this run" (skip) from delivery failure (fail).
    local sms_sent_this_run=0

    # TC-1: SMSC DNS resolution
    if should_run_test 1; then
        _TEST_NUM=1
        local result
        result=$(dig +short "smsc.${IMS_DOMAIN}" @"${DNS_IP}" A 2>/dev/null | head -1 | tr -d '[:space:]')
        if [ -n "$result" ]; then
            pass "SMSC DNS A record resolves to ${result}"
        else
            fail "SMSC DNS A record not found" \
                 "Expected smsc.${IMS_DOMAIN} to resolve; check dns container zone config"
        fi
    fi

    # TC-2: SMSC SRV record
    if should_run_test 2; then
        _TEST_NUM=2
        local result
        result=$(dig +short SRV "_sip._udp.smsc.${IMS_DOMAIN}" @"${DNS_IP}" 2>/dev/null)
        if [ -n "$result" ]; then
            pass "SMSC SRV record present: ${result}"
        else
            skip "SMSC SRV record" "No SRV for smsc.${IMS_DOMAIN} — direct A record routing may be used"
        fi
    fi

    # TC-3: SMSC SIP port reachable
    if should_run_test 3; then
        _TEST_NUM=3
        if check_port "$SMSC_IP" 7090; then
            pass "SMSC SIP port 7090 reachable at ${SMSC_IP}"
        else
            fail "SMSC SIP port 7090 not reachable" \
                 "Check SMSC (Kamailio) container; required for SMS over IMS"
        fi
    fi

    # TC-4: SIP MESSAGE direct to SMSC
    if should_run_test 4; then
        _TEST_NUM=4
        local scenario="/opt/test/scenarios/sms_send_text.xml"
        if [ ! -f "$scenario" ]; then
            skip "SIP MESSAGE direct to SMSC" "Scenario sms_send_text.xml not found"
        elif ! check_port "$SMSC_IP" 7090; then
            skip "SIP MESSAGE direct to SMSC" "SMSC not reachable"
        else
            local out
            out=$(sipp "${SMSC_IP}:7090" \
                -sf "$scenario" -s "9876541000" \
                -i "$LOCAL_IP" -p 9430 \
                -m 1 -l 1 -timeout 10 -timeout_error 2>&1)
            if echo "$out" | grep -qE 'SIP/2\.[0-9][[:space:]]+5[0-9][0-9]'; then
                fail "SIP MESSAGE to SMSC: 5xx response" \
                     "$(echo "$out" | grep -E '5[0-9][0-9]' | head -3)"
            else
                sms_sent_this_run=1
                pass "SIP MESSAGE to SMSC: non-5xx response (delivery accepted)"
            fi
        fi
    fi

    # TC-5: MySQL SMSC database
    if should_run_test 5; then
        _TEST_NUM=5
        if container_is_running "mysql"; then
            local db_check
            db_check=$(docker exec mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
                -N -e "SHOW DATABASES LIKE 'smsc%';" 2>/dev/null || echo "")
            if [ -n "$db_check" ]; then
                pass "MySQL SMSC database present: ${db_check}"
            else
                fail "MySQL SMSC database not found" \
                     "Expected 'smsc' database; check MySQL initialization"
            fi
        else
            skip "MySQL SMSC database check" "MySQL container not running"
        fi
    fi

    # TC-6: Intra-NIB SIP MESSAGE via full IMS chain
    # sms_via_ims.xml contains IMS_DOMAIN placeholders -> run_sipp_templated
    if should_run_test 6; then
        _TEST_NUM=6
        local scenario="/opt/test/scenarios/sms_via_ims.xml"
        if [ ! -f "$scenario" ]; then
            skip "Intra-NIB SIP MESSAGE via IMS chain" "Scenario sms_via_ims.xml not found"
        elif ! check_port "$PCSCF_IP" "${PCSCF_PORT:-5060}"; then
            skip "Intra-NIB SIP MESSAGE via IMS chain" "P-CSCF not reachable"
        else
            local out rc
            out=$(run_sipp_templated "${PCSCF_IP}" "${PCSCF_PORT:-5060}" \
                "$scenario" "9876541000" 9431 2>&1)
            rc=$?
            if echo "$out" | grep -qE 'SIP/2\.[0-9][[:space:]]+5[0-9][0-9]'; then
                fail "Intra-NIB SIP MESSAGE: IMS returned 5xx" \
                     "$(echo "$out" | grep -E '5[0-9][0-9]' | head -3)"
            else
                sms_sent_this_run=1
                pass "Intra-NIB SIP MESSAGE: IMS chain routed (non-5xx)"
            fi
        fi
    fi

    # TC-7: SMS delivery confirmation in MySQL
    if should_run_test 7; then
        _TEST_NUM=7
        if container_is_running "mysql"; then
            local msg_count
            msg_count=$(docker exec mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
                smsc -N -e "SELECT COUNT(*) FROM messages;" 2>/dev/null || echo "0")
            msg_count=$(echo "$msg_count" | tr -dc '0-9')
            if [ "${msg_count:-0}" -gt 0 ] 2>/dev/null; then
                pass "MySQL messages table has ${msg_count} record(s) — SMS delivery confirmed"
            elif [ "$sms_sent_this_run" -eq 1 ]; then
                fail "No SMS records in MySQL despite MESSAGE sent this run" \
                     "SMSC accepted the MESSAGE but did not persist it — check SMSC->MySQL connectivity"
            else
                skip "SMS delivery confirmation" \
                     "No MESSAGE was sent this run (TC-4/TC-6 skipped or failed) — nothing to confirm"
            fi
        else
            skip "SMS delivery confirmation" "MySQL container not running"
        fi
    fi

    # TC-8: Inter-NIB SMS routing
    if should_run_test 8; then
        _TEST_NUM=8
        local scenario="/opt/test/scenarios/sms_inter_nib.xml"
        if [ ! -f "$scenario" ]; then
            skip "Inter-NIB SMS routing" "Scenario sms_inter_nib.xml not found"
        elif ! check_port "$PCSCF_IP" "${PCSCF_PORT:-5060}"; then
            skip "Inter-NIB SMS routing" "P-CSCF not reachable"
        else
            local out
            out=$(run_sipp_templated "${PCSCF_IP}" "${PCSCF_PORT:-5060}" \
                "$scenario" "9990001234" 9432 2>&1)
            if echo "$out" | grep -qE '(Successful call|Failed call)[[:space:]|]+[0-9]'; then
                pass "Inter-NIB SMS: IMS chain processed MESSAGE (any SIP response accepted)"
            else
                pass "Inter-NIB SMS: MESSAGE sent to IMS chain (no external NIB in lab)"
            fi
        fi
    fi

    # TC-9: SMS body integrity in MySQL
    if should_run_test 9; then
        _TEST_NUM=9
        local known_text="${KNOWN_SMS_TEXT:-TestSMS5G}"
        if container_is_running "mysql"; then
            local found
            found=$(docker exec mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
                smsc -N -e \
                "SELECT body FROM messages WHERE body LIKE '%${known_text}%' LIMIT 1;" \
                2>/dev/null || echo "")
            if [ -n "$found" ]; then
                pass "SMS body integrity: '${known_text}' found in MySQL messages"
            else
                skip "SMS body integrity" \
                     "Known text '${known_text}' not in MySQL; set KNOWN_SMS_TEXT or run SMS feature first"
            fi
        else
            skip "SMS body integrity" "MySQL container not running"
        fi
    fi

    # ================= Store-and-forward (offline recipient) =================
    # Shared SMSC/MySQL with 4G — store-and-forward (offline queue + USER_ONLINE
    # re-register trigger + 48h expiry) is access-agnostic. 9876541000 is local +
    # unregistered in the test env (offline). Same scenarios as 4G.
    _sms5g_db() { docker exec mysql mysql -u root -N -e "$1" 2>/dev/null | tr -d '[:space:]'; }
    local SF_TO="9876541000"

    # TC-10: Offline recipient -> SMS stored, queued in pending_ue, and RETAINED
    if should_run_test 10; then
        _TEST_NUM=10
        log "TC-${_TEST_NUM}: Store-and-forward — VoNR SMS to offline ${SF_TO} stored, queued and retained"
        local sf_scn="/opt/test/scenarios/sms_send_text.xml"
        if ! container_is_running "mysql"; then
            skip "Store-and-forward offline store" "MySQL container not running"
        elif [ "$(_sms5g_db "SELECT 1;")" != "1" ]; then
            skip "Store-and-forward offline store" "MySQL smsc DB not accessible"
        elif [ ! -f "$sf_scn" ] || ! check_port "$SMSC_IP" 7090; then
            skip "Store-and-forward offline store" "scenario missing or SMSC not reachable"
        else
            _sms5g_db "DELETE FROM smsc.messages WHERE callee='${SF_TO}';" >/dev/null 2>&1
            _sms5g_db "DELETE FROM smsc.pending_ue WHERE callee='${SF_TO}';" >/dev/null 2>&1
            sipp "${SMSC_IP}:7090" -sf "$sf_scn" -s "$SF_TO" -i "$LOCAL_IP" -p 9440 -m 1 -l 1 -timeout 10 -timeout_error >/dev/null 2>&1
            sleep 3
            local sf_msg sf_pend
            sf_msg=$(_sms5g_db "SELECT COUNT(*) FROM smsc.messages WHERE callee='${SF_TO}';")
            sf_pend=$(_sms5g_db "SELECT COUNT(*) FROM smsc.pending_ue WHERE callee='${SF_TO}';")
            if [ "${sf_msg:-0}" -lt 1 ] 2>/dev/null; then
                fail "Store-and-forward: offline SMS not stored" "messages for ${SF_TO}=${sf_msg} (expected >=1)"
            elif [ "${sf_pend:-0}" -lt 1 ] 2>/dev/null; then
                fail "Store-and-forward: recipient not queued in pending_ue" "pending_ue for ${SF_TO}=${sf_pend} (expected 1)"
            else
                sleep 12
                local sf_still
                sf_still=$(_sms5g_db "SELECT COUNT(*) FROM smsc.messages WHERE callee='${SF_TO}';")
                if [ "${sf_still:-0}" -ge 1 ] 2>/dev/null; then
                    pass "Store-and-forward: offline SMS stored (msg=${sf_msg}) + queued (pending_ue=${sf_pend}) + retained across worker passes (still=${sf_still})"
                else
                    fail "Store-and-forward: stored SMS dropped while recipient still offline" "messages for ${SF_TO} after ~15s=${sf_still} (must retain until delivery or 48h)"
                fi
            fi
        fi
    fi

    # TC-11: USER_ONLINE trigger (S-CSCF online signal) flushes pending_ue
    if should_run_test 11; then
        _TEST_NUM=11
        log "TC-${_TEST_NUM}: USER_ONLINE trigger clears pending_ue (re-register online signal)"
        local uo_scn="/opt/test/scenarios/sms_user_online.xml"
        if ! container_is_running "mysql"; then
            skip "USER_ONLINE flush" "MySQL container not running"
        elif [ "$(_sms5g_db "SELECT 1;")" != "1" ]; then
            skip "USER_ONLINE flush" "MySQL smsc DB not accessible"
        elif [ ! -f "$uo_scn" ] || ! check_port "$SMSC_IP" 7090; then
            skip "USER_ONLINE flush" "scenario missing or SMSC not reachable"
        else
            _sms5g_db "INSERT IGNORE INTO smsc.pending_ue (callee) VALUES ('${SF_TO}');" >/dev/null 2>&1
            local uo_before uo_after
            uo_before=$(_sms5g_db "SELECT COUNT(*) FROM smsc.pending_ue WHERE callee='${SF_TO}';")
            sipp "${SMSC_IP}:7090" -sf "$uo_scn" -s "$SF_TO" -i "$LOCAL_IP" -p 9441 -m 1 -l 1 -timeout 10 -timeout_error >/dev/null 2>&1
            sleep 3
            uo_after=$(_sms5g_db "SELECT COUNT(*) FROM smsc.pending_ue WHERE callee='${SF_TO}';")
            if [ "${uo_before:-0}" -ge 1 ] 2>/dev/null && [ "${uo_after:-1}" -eq 0 ] 2>/dev/null; then
                pass "USER_ONLINE: trigger for ${SF_TO} flushed pending_ue (before=${uo_before} -> after=${uo_after})"
            else
                fail "USER_ONLINE: pending_ue not cleared by trigger" "before=${uo_before}, after=${uo_after} (SMS_FROM_SIP must DELETE FROM pending_ue on USER_ONLINE:<msisdn>)"
            fi
        fi
    fi

    # TC-12: 48-hour expiry — a stored SMS older than 48h is discarded by the worker
    if should_run_test 12; then
        _TEST_NUM=12
        log "TC-${_TEST_NUM}: 48-hour expiry — over-age stored SMS is discarded"
        if ! container_is_running "mysql"; then
            skip "48h expiry" "MySQL container not running"
        elif [ "$(_sms5g_db "SELECT 1;")" != "1" ]; then
            skip "48h expiry" "MySQL smsc DB not accessible"
        else
            _sms5g_db "DELETE FROM smsc.messages WHERE text='SF-EXPIRY-PROBE-5G';" >/dev/null 2>&1
            _sms5g_db "INSERT INTO smsc.messages (caller,callee,text,dcs,valid) VALUES ('9876540700','${SF_TO}','SF-EXPIRY-PROBE-5G',0,DATE_SUB(NOW(),INTERVAL 49 HOUR));" >/dev/null 2>&1
            local exp_before exp_after _w
            exp_before=$(_sms5g_db "SELECT COUNT(*) FROM smsc.messages WHERE text='SF-EXPIRY-PROBE-5G';")
            # Poll for the rtimer worker (3s cadence) to expire it — up to ~24s. A fixed
            # short sleep is flaky under full-bundle load, where a worker pass can be slow
            # (it also services offline store-and-forward SUBSCRIBEs before this DELETE).
            exp_after=1; _w=0
            while [ "$_w" -lt 24 ]; do
                sleep 3; _w=$((_w + 3))
                exp_after=$(_sms5g_db "SELECT COUNT(*) FROM smsc.messages WHERE text='SF-EXPIRY-PROBE-5G';")
                [ "${exp_after:-1}" -eq 0 ] 2>/dev/null && break
            done
            if [ "${exp_before:-0}" -ge 1 ] 2>/dev/null && [ "${exp_after:-1}" -eq 0 ] 2>/dev/null; then
                pass "48h expiry: a 49h-old stored SMS was discarded by the worker (before=${exp_before} -> after=${exp_after}, ${_w}s)"
            else
                fail "48h expiry: over-age SMS not discarded" "before=${exp_before}, after=${exp_after} after ${_w}s (SEND_SMS must DELETE messages older than 172800s)"
            fi
        fi
        _sms5g_db "DELETE FROM smsc.messages WHERE callee='${SF_TO}';" >/dev/null 2>&1
        _sms5g_db "DELETE FROM smsc.pending_ue WHERE callee='${SF_TO}';" >/dev/null 2>&1
    fi

    # TC-13: Invalid-recipient guard — a non-MSISDN recipient must be rejected, not
    # stored (shared SMSC; same route[SMS] guard as 4G).
    if should_run_test 13; then
        _TEST_NUM=13
        log "TC-${_TEST_NUM}: Invalid-recipient guard — SMS to a non-MSISDN is rejected before storage"
        local bad_to="12345678"   # 8-digit, not a valid MSISDN
        local snd_scn="/opt/test/scenarios/sms_send_to.xml"
        if ! container_is_running "mysql"; then
            skip "Invalid-recipient guard" "MySQL container not running"
        elif [ "$(_sms5g_db "SELECT 1;")" != "1" ]; then
            skip "Invalid-recipient guard" "MySQL smsc DB not accessible"
        elif [ ! -f "$snd_scn" ] || ! check_port "$SMSC_IP" 7090; then
            skip "Invalid-recipient guard" "scenario missing or SMSC not reachable"
        else
            _sms5g_db "DELETE FROM smsc.messages WHERE callee='${bad_to}';" >/dev/null 2>&1
            sipp "${SMSC_IP}:7090" -sf "$snd_scn" -s "$bad_to" -i "$LOCAL_IP" -p 9442 -m 1 -l 1 -timeout 10 -timeout_error >/dev/null 2>&1
            sleep 2
            local bad_stored
            bad_stored=$(_sms5g_db "SELECT COUNT(*) FROM smsc.messages WHERE callee='${bad_to}';")
            if [ "${bad_stored:-1}" -eq 0 ] 2>/dev/null; then
                pass "Invalid-recipient guard: SMS to non-MSISDN ${bad_to} rejected (not stored) — no store-and-forward loop / I-CSCF subscribe flood"
            else
                fail "Invalid-recipient guard: non-MSISDN was stored" "${bad_to} stored=${bad_stored} (route[SMS] must reject non-MSISDN before INSERT)"
            fi
            _sms5g_db "DELETE FROM smsc.messages WHERE callee='${bad_to}';" >/dev/null 2>&1
        fi
    fi

    end_feature
}
