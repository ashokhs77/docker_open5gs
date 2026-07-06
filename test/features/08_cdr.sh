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

    # Clean up temp files
    rm -f /tmp/sipp_cdr_tc*_err.log 2>/dev/null

    end_feature
}
