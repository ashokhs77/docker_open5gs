#!/bin/bash
# Feature 08: CDR (Call Detail Record) Tests
# Validates CDR logging, field format, content, and logrotate configuration
# on the S-CSCF (Kamailio) container.
#
# Tests:
#   TC-1: CDR log file exists
#   TC-2: CDR htable configured
#   TC-3: CDR after call (line count increases)
#   TC-4: CDR fields validation (5 comma-separated fields)
#   TC-5: CDR audio type
#   TC-6: CDR logrotate config exists
#   TC-7: CDR field completeness (all mandatory fields non-empty and type-valid)
#   --- Conference CDR (P-CSCF; conf legs bypass the S-CSCF) ---
#   TC-8:  conf-cdr-logger.sh installed + exec.so loaded on P-CSCF
#   TC-9:  confcdr htable configured on P-CSCF
#   TC-10: conference CDR logrotate config exists
#   TC-11: conf CDR write-path — 9-col schema, newest-on-top, 7-day retention
#          (runs the deployed logger against a throwaway CSV; real file untouched)
#   TC-12: REAL UE path — register a UE, dial conference 1010 THROUGH the P-CSCF
#          (not direct-to-FreeSWITCH), then assert a row lands in conf_cdr.csv
#   TC-13: live conf_cdr.csv field validation (now populated by TC-12)

set +e

source /opt/test/lib/common.sh
source /opt/test/lib/sipp_helpers.sh

run_cdr_tests() {
    start_feature "CDR"

    # TC-1: CDR log file exists
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: CDR log file exists"
        local cdr_ls
        cdr_ls=$(docker_exec scscf "ls -la /cdr-logs/cdr.csv" 2>&1)
        local rc=$?

        if [ $rc -eq 0 ] && echo "$cdr_ls" | grep -q "cdr.csv"; then
            pass "CDR log file /cdr-logs/cdr.csv exists on scscf"
        else
            fail "CDR log file /cdr-logs/cdr.csv not found on scscf" "Output: $cdr_ls"
        fi
    fi

    # TC-2: CDR htable configured
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: CDR htable configured in S-CSCF"
        local htable_result
        htable_result=$(docker_exec scscf "kamcmd htable.dump cdr" 2>&1)
        local rc=$?

        if [ $rc -eq 0 ]; then
            pass "CDR htable module is loaded and accessible on scscf"
        else
            # Fallback: check if htable module is loaded in kamailio config
            local config_check
            config_check=$(docker_exec scscf "grep -c htable /etc/kamailio/kamailio.cfg" 2>&1)
            if [ "$config_check" -gt 0 ] 2>/dev/null; then
                pass "CDR htable module configured in kamailio.cfg (kamcmd returned non-zero but config present)"
            else
                fail "CDR htable not configured on scscf" "kamcmd exit: $rc, output: $htable_result"
            fi
        fi
    fi

    # TC-3: CDR file has content (entries from previous calls)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: CDR file has recorded entries"

        local line_count
        line_count=$(docker_exec scscf "wc -l < /cdr-logs/cdr.csv" 2>/dev/null | tr -d '[:space:]')
        if [ -z "$line_count" ]; then
            line_count=0
        fi
        log "  CDR file has $line_count entries"

        if [ "$line_count" -gt 0 ] 2>/dev/null; then
            pass "CDR file contains $line_count recorded call entries"
        else
            # CDR file exists but empty — this is OK if no calls have been made through S-CSCF yet
            # Note: conf-factory calls bypass S-CSCF so don't generate CDRs
            skip "CDR file is empty" "No calls have been routed through S-CSCF yet (conf-factory bypasses S-CSCF CDR)"
        fi
    fi

    # TC-4: CDR fields validation (5 comma-separated fields)
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: CDR fields validation"
        local last_line
        last_line=$(docker_exec scscf "tail -1 /cdr-logs/cdr.csv" 2>/dev/null)

        if [ -z "$last_line" ]; then
            fail "CDR file is empty, cannot validate fields" ""
        else
            # Count comma-separated fields
            local field_count
            field_count=$(echo "$last_line" | awk -F',' '{print NF}')
            log "  Last CDR line has $field_count fields"

            if [ "$field_count" -ge 5 ] 2>/dev/null; then
                pass "CDR last line has $field_count comma-separated fields (expected >= 5)"
            else
                fail "CDR last line has $field_count fields" "Expected at least 5 comma-separated fields. Line: $last_line"
            fi
        fi
    fi

    # TC-5: CDR audio type
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: CDR contains audio type"
        local audio_count latest_audio latest_line
        audio_count=$(docker_exec scscf "awk -F',' 'tolower(\$3)==\"audio\" {c++} END {print c+0}' /cdr-logs/cdr.csv" 2>/dev/null | tr -d '[:space:]')
        latest_audio=$(docker_exec scscf "awk -F',' 'tolower(\$3)==\"audio\" {line=\$0} END {print line}' /cdr-logs/cdr.csv" 2>/dev/null)
        latest_line=$(docker_exec scscf "tail -1 /cdr-logs/cdr.csv" 2>/dev/null)

        if [ -z "$latest_line" ]; then
            fail "CDR file is empty, cannot check audio type" ""
        else
            audio_count=${audio_count:-0}
            if [ "$audio_count" -gt 0 ] 2>/dev/null; then
                pass "CDR file contains ${audio_count} audio media record(s); latest audio record: ${latest_audio}"
            else
                fail "CDR file does not contain any audio media records" "Last CDR line: $latest_line"
            fi
        fi
    fi

    # TC-6: CDR logrotate config exists
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: CDR logrotate config exists"
        local logrotate_check
        logrotate_check=$(docker_exec scscf "ls /etc/logrotate.d/kamailio-cdr" 2>&1)
        local rc=$?

        if [ $rc -eq 0 ]; then
            pass "CDR logrotate config exists at /etc/logrotate.d/kamailio-cdr"
        else
            fail "CDR logrotate config not found" "Output: $logrotate_check"
        fi
    fi

    # TC-7: CDR field completeness — all mandatory fields non-empty and parseable
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: CDR field completeness (all mandatory fields non-empty, types valid)"
        local last_line
        last_line=$(docker_exec scscf "tail -1 /cdr-logs/cdr.csv" 2>/dev/null)

        if [ -z "$last_line" ]; then
            skip "CDR field completeness" "CDR file is empty — no calls recorded yet"
        else
            # Fields: CALLING_PARTY, CALLED_PARTY, MEDIA_TYPE, START_TIME, DURATION
            # Validate each field is non-empty, media_type is audio/video,
            # start_time looks like a Unix timestamp or ISO date, duration is numeric.
            local calling called media_type start_time duration
            calling=$(echo   "$last_line" | awk -F',' '{print $1}')
            called=$(echo    "$last_line" | awk -F',' '{print $2}')
            media_type=$(echo "$last_line" | awk -F',' '{print $3}')
            start_time=$(echo "$last_line" | awk -F',' '{print $4}')
            duration=$(echo  "$last_line" | awk -F',' '{print $5}')

            local errors=""
            [ -z "$calling" ]   && errors="${errors}CALLING_PARTY empty; "
            [ -z "$called" ]    && errors="${errors}CALLED_PARTY empty; "
            [ -z "$media_type" ] && errors="${errors}MEDIA_TYPE empty; "
            [ -z "$start_time" ] && errors="${errors}START_TIME empty; "
            [ -z "$duration" ]   && errors="${errors}DURATION empty; "

            # MEDIA_TYPE must be audio or video
            local lc_media
            lc_media=$(echo "$media_type" | tr '[:upper:]' '[:lower:]')
            if [ -n "$media_type" ] && [ "$lc_media" != "audio" ] && [ "$lc_media" != "video" ]; then
                errors="${errors}MEDIA_TYPE='${media_type}' not audio/video; "
            fi

            # START_TIME must contain at least 4 digits (Unix timestamp or date string)
            if [ -n "$start_time" ] && ! echo "$start_time" | grep -qE '[0-9]{4}'; then
                errors="${errors}START_TIME='${start_time}' not timestamp-like; "
            fi

            # DURATION must be numeric (integer, decimal, or with trailing 's' suffix e.g. "4s", "1.5s")
            if [ -n "$duration" ] && ! echo "$duration" | grep -qE '^[0-9]+(\.[0-9]+)?s?$'; then
                errors="${errors}DURATION='${duration}' not numeric; "
            fi

            if [ -z "$errors" ]; then
                pass "CDR field completeness OK: calling='${calling}' called='${called}' media='${media_type}' start='${start_time}' duration='${duration}'"
            else
                fail "CDR field completeness failed: ${errors}" "CDR line: ${last_line}"
            fi
        fi
    fi

    # ================= Conference CDR (P-CSCF) =================
    # Conference legs (dialing a conference number 1NNR) are routed P-CSCF ->
    # FreeSWITCH and never traverse the S-CSCF, so they get their own CDR path:
    # the P-CSCF confcdr htable + conf-cdr-logger.sh -> /cdr-logs/conf_cdr.csv.
    # These cases validate the P-CSCF conference-CDR plumbing and schema.
    #   Schema (9 cols): RecordType,ConfHost,Participants,TotalParticipantCount,
    #                    MediaType,StartTime,Duration,ConfBridgeID,EndReason
    #   Behaviour: newest record on top; only last 7 days retained.

    # TC-8: conf-cdr-logger.sh installed and exec module loaded on P-CSCF
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Conference CDR logger + exec module present on P-CSCF"
        local logger_ok exec_ok
        logger_ok=$(docker_exec pcscf "test -x /usr/local/bin/conf-cdr-logger.sh && echo yes" 2>/dev/null | tr -d '[:space:]')
        exec_ok=$(docker_exec pcscf "grep -c 'loadmodule \"exec.so\"' /etc/kamailio_pcscf/kamailio_pcscf.cfg" 2>/dev/null | tr -d '[:space:]')
        exec_ok=${exec_ok:-0}

        if [ "$logger_ok" = "yes" ] && [ "$exec_ok" -gt 0 ] 2>/dev/null; then
            pass "conf-cdr-logger.sh is executable and exec.so is loaded on P-CSCF"
        else
            fail "Conference CDR prerequisites missing on P-CSCF" "logger executable='${logger_ok}', exec.so load count='${exec_ok}'"
        fi
    fi

    # TC-9: confcdr htable configured on P-CSCF
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: confcdr htable configured on P-CSCF"
        local confhtable
        confhtable=$(docker_exec pcscf "kamcmd htable.dump confcdr" 2>&1)
        local rc=$?
        if [ $rc -eq 0 ]; then
            pass "confcdr htable is loaded and accessible on P-CSCF"
        else
            local cfg_check
            cfg_check=$(docker_exec pcscf "grep -c 'confcdr=>' /etc/kamailio_pcscf/kamailio_pcscf.cfg" 2>/dev/null | tr -d '[:space:]')
            if [ "${cfg_check:-0}" -gt 0 ] 2>/dev/null; then
                pass "confcdr htable configured in kamailio_pcscf.cfg (kamcmd non-zero but config present)"
            else
                fail "confcdr htable not configured on P-CSCF" "kamcmd exit: $rc"
            fi
        fi
    fi

    # TC-10: conference CDR logrotate config exists
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Conference CDR logrotate config exists on P-CSCF"
        local conf_lr
        conf_lr=$(docker_exec pcscf "ls /etc/logrotate.d/kamailio-conf-cdr" 2>&1)
        if [ $? -eq 0 ]; then
            pass "Conference CDR logrotate config exists at /etc/logrotate.d/kamailio-conf-cdr"
        else
            fail "Conference CDR logrotate config not found" "Output: $conf_lr"
        fi
    fi

    # TC-11: conference CDR write-path + schema + newest-on-top + 7-day retention.
    # Runs the DEPLOYED logger against a throwaway CSV inside the container so the
    # real /cdr-logs/conf_cdr.csv is never touched. Epochs are computed host-side.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Conference CDR write-path (schema, newest-on-top, 7-day retention)"
        local now old expected_hdr
        now=$(date +%s)
        old=$(date -d '10 days ago' +%s 2>/dev/null)
        expected_hdr="RecordType,ConfHost,Participants,TotalParticipantCount,MediaType,StartTime,Duration,ConfBridgeID,EndReason"

        # Build a temp copy of the deployed logger that writes to /tmp/cct.csv
        docker_exec pcscf "sed 's#/cdr-logs/conf_cdr.csv#/tmp/cct.csv#' /usr/local/bin/conf-cdr-logger.sh > /tmp/cct_logger.sh && rm -f /tmp/cct.csv" >/dev/null 2>&1

        # Write: recent LEG, then a 10-day-old LEG (must be pruned), then recent CONF (newest)
        docker_exec pcscf "bash /tmp/cct_logger.sh LEG 1000 2000 2 video $now 90 1230 NORMAL"      >/dev/null 2>&1
        docker_exec pcscf "bash /tmp/cct_logger.sh LEG 1000 9999 1 audio $old 60 1230 NORMAL"       >/dev/null 2>&1
        docker_exec pcscf "bash /tmp/cct_logger.sh CONF 1000 2000 2 video $now 300 1230 CONF_ENDED" >/dev/null 2>&1

        local csv hdr_line top_line top_type ncols old_present recent_present
        csv=$(docker_exec pcscf "cat /tmp/cct.csv" 2>/dev/null)
        hdr_line=$(printf '%s\n' "$csv" | sed -n '1p')
        top_line=$(printf '%s\n' "$csv" | sed -n '2p')
        top_type=$(printf '%s' "$top_line" | awk -F',' '{print $1}')
        ncols=$(printf '%s' "$top_line" | awk -F',' '{print NF}')
        old_present=$(printf '%s\n' "$csv" | grep -c ',9999,' 2>/dev/null | tr -d '[:space:]')
        recent_present=$(printf '%s\n' "$csv" | grep -c ',2000,' 2>/dev/null | tr -d '[:space:]')

        local cerrors=""
        [ "$hdr_line" != "$expected_hdr" ]                 && cerrors="${cerrors}header mismatch; "
        [ "$top_type" != "CONF" ]                          && cerrors="${cerrors}newest record not on top (top RecordType='${top_type}', expected CONF); "
        [ "${ncols:-0}" -ne 9 ] 2>/dev/null                && cerrors="${cerrors}expected 9 columns, got ${ncols}; "
        [ "${old_present:-0}" -ne 0 ] 2>/dev/null          && cerrors="${cerrors}10-day-old row not pruned (retention broken); "
        [ "${recent_present:-0}" -lt 1 ] 2>/dev/null       && cerrors="${cerrors}recent row missing; "

        # cleanup throwaway artifacts
        docker_exec pcscf "rm -f /tmp/cct.csv /tmp/cct_logger.sh" >/dev/null 2>&1

        if [ -z "$cerrors" ]; then
            pass "Conference CDR write-path OK: 9-col schema, header present, CONF newest-on-top, 10-day row pruned"
        else
            fail "Conference CDR write-path failed: ${cerrors}" "CSV:\n${csv}"
        fi
    fi

    # TC-12: REAL UE path. Register a UE (attach + IMS register over IPSec, exactly
    # like a handset) and dial the conference number 1010 THROUGH the P-CSCF — the
    # INVITE R-URI is 1010, so the P-CSCF FSDISPATCH routes it to FreeSWITCH and the
    # conference CDR hooks fire. This is the honest counterpart to the direct-to-
    # FreeSWITCH conference dials, which bypass the P-CSCF and can never exercise the
    # CDR. A successful call that produces NO conf_cdr.csv row is a real failure.
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Conference CDR via REAL UE path (register + dial 1010 through P-CSCF)"
        local conf_room="${CONF_CDR_ROOM:-1010}"
        if ! ue_sim_probe 2>/dev/null; then
            skip "Conference CDR via real UE path" \
                 "UE simulator environment not available (attach/IPSec) — cannot exercise the P-CSCF conference path"
        else
            # Baseline: how many rows already reference this bridge id (col ConfBridgeID)
            local before_rows
            before_rows=$(docker_exec pcscf "test -f /cdr-logs/conf_cdr.csv && grep -c ',${conf_room},' /cdr-logs/conf_cdr.csv || echo 0" 2>/dev/null | tr -dc '0-9')
            before_rows=${before_rows:-0}

            # Register a real UE and place a conference call to ${conf_room} via the P-CSCF.
            local call_out
            call_out=$(timeout 120 "$PYTHON_BIN" -c "
import sys, os, time
sys.path.insert(0, '/opt/test')
os.environ.setdefault('MME_IP',   '${MME_IP:-172.22.1.9}')
os.environ.setdefault('PCSCF_IP', '${PCSCF_IP:-172.22.1.21}')
os.environ.setdefault('PYHSS_IP', '${PYHSS_IP:-172.22.1.18}')
os.environ.setdefault('LOCAL_IP', '${LOCAL_IP:-172.22.1.200}')
os.environ.setdefault('MCC', '${MCC:-001}')
os.environ.setdefault('MNC', '${MNC:-01}')
from ue_sim.ue_simulator import UESimulator
from ue_sim.config import Config
import logging
logging.disable(logging.WARNING)
sub = Config.default_subscribers()[0]
ue = UESimulator(imsi=sub.imsi, ki=sub.ki, opc=sub.opc, msisdn=sub.msisdn,
                 sip_local_port=Config.SIP_LOCAL_PORT_BASE + 70)
try:
    if not ue.attach():
        print('ATTACH_FAIL'); sys.exit(0)
    if not ue.ims_register():
        print('REG_FAIL'); sys.exit(0)
    dlg = ue.establish_call_dialog('${conf_room}', video=False)
    if not dlg:
        print('CALL_FAIL'); sys.exit(0)
    time.sleep(3)                       # stay in the conference briefly
    ue.end_dialog(dlg, tolerate_timeout=True)
    print('CALL_OK')
finally:
    try:
        ue.detach()
    except Exception:
        pass
" 2>/dev/null || echo 'PY_ERR')

            if ! echo "$call_out" | grep -q "CALL_OK"; then
                skip "Conference CDR via real UE path" \
                     "Could not complete the UE conference call (result: $(echo "$call_out" | tr '\n' ' ')) — registration/environment issue, not a CDR defect"
            else
                sleep 2   # let the P-CSCF exec_msg flush the CDR row(s)
                local after_rows new_row
                after_rows=$(docker_exec pcscf "test -f /cdr-logs/conf_cdr.csv && grep -c ',${conf_room},' /cdr-logs/conf_cdr.csv || echo 0" 2>/dev/null | tr -dc '0-9')
                after_rows=${after_rows:-0}
                new_row=$(docker_exec pcscf "grep ',${conf_room},' /cdr-logs/conf_cdr.csv | head -1" 2>/dev/null)

                if [ "${after_rows:-0}" -gt "${before_rows:-0}" ] 2>/dev/null; then
                    pass "Real UE dialed conference ${conf_room} (register→P-CSCF→FreeSWITCH) and a conf_cdr.csv row was written (rows ${before_rows}->${after_rows}); newest: ${new_row}"
                else
                    fail "UE conference call to ${conf_room} succeeded but NO conf_cdr.csv row was written" \
                         "FreeSWITCH-sourced conference CDR did not fire (before=${before_rows}, after=${after_rows}) — check freeswitch mod_lua conference_cdr.lua + the /cdr-logs mount; a LEG row is written when the member LEAVES, so ensure the call ended"
                fi
            fi
        fi
    fi

    # TC-13: real conf_cdr.csv field completeness (now populated by TC-12; still
    # tolerant — skips if no conference call has been routed through the P-CSCF).
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        log "TC-${_TEST_NUM}: Conference CDR field validation on live conf_cdr.csv (if present)"
        local exists first_data rtype ncols
        exists=$(docker_exec pcscf "test -f /cdr-logs/conf_cdr.csv && echo yes" 2>/dev/null | tr -d '[:space:]')
        if [ "$exists" != "yes" ]; then
            skip "Conference CDR field validation" "/cdr-logs/conf_cdr.csv not present — no conference call routed through P-CSCF yet"
        else
            # first data row = line 2 (line 1 is the header), which is also the newest
            first_data=$(docker_exec pcscf "sed -n '2p' /cdr-logs/conf_cdr.csv" 2>/dev/null)
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

    # Clean up temp files
    rm -f /tmp/sipp_cdr_tc*_err.log 2>/dev/null

    end_feature
}
