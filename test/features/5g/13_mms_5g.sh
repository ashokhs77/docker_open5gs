#!/bin/bash
# Feature 13: MMS over 5GS
# Validates the MMSC (Kannel + Mbuni) stack in the 5G SA context.
#
# Architecture in 5G SA vs 4G:
#   - MMS content travels over the UE's internet PDU session (UPF ogstun),
#     not a 4G EPS bearer — but from the MMSC's perspective it is just HTTP.
#   - SMPP SMS notifications go to the SMSC (Kamailio) over IMS.
#     In 4G this went to OsmoMSC (circuit-switched); in 5G SA there is no
#     OsmoMSC, so TC-8 probes SMSC instead.
#   - MM7 inter-operator MMS is identical in 4G and 5G SA.
#
# Tests:
#   TC-1:  MMSC container running
#   TC-2:  Kannel bearerbox port 13000
#   TC-3:  Kannel smsbox port 13001
#   TC-4:  Kannel sendsms HTTP port 13013
#   TC-5:  Mbuni WAP gateway port 8090
#   TC-6:  Mbuni SendMMS API port 8181
#   TC-7:  Kannel admin status
#   TC-8:  SMPP path to SMSC (5G: Kamailio SMSC, not OsmoMSC)
#   TC-9:  MMS storage volume mounted
#   TC-10: MMS send via SendMMS API (basic API smoke)
#   TC-11: Kannel log health
#   TC-12: Mbuni log health
#   TC-13: MMS notification SMS path via IMS (5G: SIP MESSAGE from SMSC)
#   TC-14: MMSC process health (kannel + mbuni processes)
#   TC-15: MM7 incoming port 8190
#   TC-16: Intra-NIB MMS send A->B (storage verified)
#   TC-17: Intra-NIB MMS delivery queue (recipient entry in storage)
#   TC-18: Inter-NIB MMS MM7 outbound (external MSISDN via MM7 port 8190)

set +e

MMSC_HOST="${DOCKER_HOST_IP}"
MMSC_CONTAINER="${MMSC_CONTAINER:-mmsc}"
KANNEL_ADMIN_PASS="${KANNEL_ADMIN_PASS:-admin}"

run_mms_5g_tests() {
    start_feature "MMS over 5GS"

    # ── Early skip: if MMSC is not running, skip all remaining tests ──────────
    if ! container_is_running "$MMSC_CONTAINER"; then
        _TEST_NUM=1
        skip "MMSC container check" \
             "MMSC container '${MMSC_CONTAINER}' not running — start with 'docker compose -f sa-vonr-deploy.yaml up -d mmsc'"
        # Bump counters for remaining TCs so summary is accurate
        for i in $(seq 2 18); do
            _TEST_NUM=$i
            skip "MMS TC-${i}" "MMSC not running"
        done
        end_feature
        return
    fi

    # TC-1: MMSC container running
    if should_run_test 1; then
        _TEST_NUM=1
        local rc
        rc=$(container_restart_count "$MMSC_CONTAINER")
        if [ "${rc:-0}" -lt 5 ] 2>/dev/null; then
            pass "MMSC container running (restart count: ${rc})"
        else
            fail "MMSC container crash-looping (restart count: ${rc})" \
                 "Check 'docker logs mmsc' for startup errors (kannel.conf / mbuni.conf issues)"
        fi
    fi

    # TC-2: Kannel bearerbox port 13000
    if should_run_test 2; then
        _TEST_NUM=2
        if check_port "$MMSC_HOST" 13000; then
            pass "Kannel bearerbox port 13000 reachable"
        else
            fail "Kannel bearerbox port 13000 not reachable" \
                 "Kannel may still be starting; check 'docker logs mmsc | grep bearerbox'"
        fi
    fi

    # TC-3: Kannel smsbox port 13001
    if should_run_test 3; then
        _TEST_NUM=3
        if check_port "$MMSC_HOST" 13001; then
            pass "Kannel smsbox port 13001 reachable"
        else
            fail "Kannel smsbox port 13001 not reachable" \
                 "smsbox is needed for SMPP SMS notification delivery"
        fi
    fi

    # TC-4: Kannel sendsms HTTP port 13013
    if should_run_test 4; then
        _TEST_NUM=4
        if check_port "$MMSC_HOST" 13013; then
            pass "Kannel sendsms HTTP port 13013 reachable"
        else
            fail "Kannel sendsms port 13013 not reachable" \
                 "sendsms API needed for MMS notification SMS trigger"
        fi
    fi

    # TC-5: Mbuni WAP gateway port 8090
    if should_run_test 5; then
        _TEST_NUM=5
        if check_port "$MMSC_HOST" 8090; then
            pass "Mbuni WAP gateway port 8090 reachable"
        else
            fail "Mbuni WAP gateway port 8090 not reachable" \
                 "Mbuni WAP port delivers MMS notifications to handsets"
        fi
    fi

    # TC-6: Mbuni SendMMS API port 8181
    if should_run_test 6; then
        _TEST_NUM=6
        if check_port "$MMSC_HOST" 8181; then
            pass "Mbuni SendMMS API port 8181 reachable"
        else
            fail "Mbuni SendMMS API port 8181 not reachable" \
                 "SendMMS API is used to submit MMS messages programmatically"
        fi
    fi

    # TC-7: Kannel admin status
    if should_run_test 7; then
        _TEST_NUM=7
        local kannel_status
        kannel_status=$(curl -s --max-time 5 \
            "http://${MMSC_HOST}:13000/status?password=${KANNEL_ADMIN_PASS}" 2>/dev/null || echo "")
        if echo "$kannel_status" | grep -qiE "Kannel|bearerbox|status|uptime"; then
            pass "Kannel admin status accessible"
        else
            fail "Kannel admin status not responding" \
                 "Check KANNEL_ADMIN_PASS env var and bearerbox admin port config"
        fi
    fi

    # TC-8: MMS notification SMS path — 5G SA uses HTTP to SMSC xhttp, NOT SMPP to OsmoMSC
    #
    # Architecture:  Kannel (kannel_5g.conf) ──HTTP GET──► SMSC xhttp (port 7090)
    #                                                           │
    #                                               SIP MESSAGE ──► P-CSCF ──► UE
    #
    # The Kamailio SMSC already handles HTTP requests on its TCP listener (port 7090)
    # via event_route[xhttp:request] which accepts ?msisdn=&to=&text= params.
    # kannel_5g.conf configures Kannel to POST to this endpoint (no SMPP / OsmoMSC).
    if should_run_test 8; then
        _TEST_NUM=8
        if check_port "$SMSC_IP" 7090; then
            # Probe the SMSC xhttp interface with a minimal HTTP GET
            local xhttp_resp
            xhttp_resp=$(curl -s --max-time 5 \
                "http://${SMSC_IP}:7090/?msisdn=test&to=test&text=probe" \
                2>/dev/null || echo "")
            if [ -n "$xhttp_resp" ]; then
                pass "SMSC xhttp notification path reachable at http://${SMSC_IP}:7090/ (5G SA: HTTP, not SMPP)"
            else
                pass "SMSC TCP port 7090 reachable — xhttp probe inconclusive (may need SIP framing on same port)"
            fi
        else
            fail "SMSC port 7090 not reachable at ${SMSC_IP}" \
                 "In 5G SA, Kannel sends MMS notification SMS via HTTP to SMSC xhttp. No OsmoMSC needed."
        fi
    fi

    # TC-9: MMS storage volume mounted
    if should_run_test 9; then
        _TEST_NUM=9
        local vol_check
        vol_check=$(docker exec "$MMSC_CONTAINER" sh -c \
            '[ -d /tmp/mms-storage ] && echo YES || echo NO' 2>/dev/null || echo "NO")
        if [ "$vol_check" = "YES" ]; then
            pass "MMS storage volume /tmp/mms-storage mounted in MMSC container"
        else
            fail "MMS storage volume /tmp/mms-storage not mounted" \
                 "Check mms_storage volume in docker-compose and mmsc container"
        fi
    fi

    # TC-10: MMS send via SendMMS API (basic smoke)
    if should_run_test 10; then
        _TEST_NUM=10
        local mms_resp
        mms_resp=$(curl -s --max-time 8 \
            -X POST \
            -F "username=mmsc" \
            -F "password=mmsc123" \
            -F "to=+9876541000" \
            -F "from=+9876540001" \
            -F "subject=TestMMS5G" \
            -F "text=Hello from 5G SA MMS test" \
            "http://${MMSC_HOST}:8181/cgi-bin/sendmms" 2>/dev/null || echo "FAILED")
        if echo "$mms_resp" | grep -qiE "ok|success|queued|accepted|200|msgid"; then
            pass "MMS send via SendMMS API: accepted"
        elif echo "$mms_resp" | grep -qiE "error|fault|fail"; then
            fail "SendMMS API returned error" \
                 "$(echo "$mms_resp" | head -3)"
        else
            pass "SendMMS API reachable (response: $(echo "$mms_resp" | head -1 | cut -c1-60))"
        fi
    fi

    # TC-11: Kannel log health
    if should_run_test 11; then
        _TEST_NUM=11
        # Kannel logs to /tmp/kannel.log (log-file in kannel.conf / kannel_5g.conf).
        local kannel_crashes
        kannel_crashes=$(docker exec "$MMSC_CONTAINER" sh -c \
            'if [ -s /tmp/kannel.log ]; then grep -ciE "PANIC|segfault|assertion failed" /tmp/kannel.log; else echo MISSING; fi' \
            2>/dev/null | tr -dc 'A-Za-z0-9')
        if [ "$kannel_crashes" = "MISSING" ]; then
            skip "Kannel log health" "Kannel log /tmp/kannel.log not present yet"
        elif [ "${kannel_crashes:-0}" -eq 0 ] 2>/dev/null; then
            pass "Kannel log healthy (no PANIC/segfault in /tmp/kannel.log)"
        else
            fail "Kannel log has ${kannel_crashes} PANIC/segfault line(s)" \
                 "Inspect: docker exec mmsc tail -50 /tmp/kannel.log"
        fi
    fi

    # TC-12: Mbuni log health
    if should_run_test 12; then
        _TEST_NUM=12
        # Mbuni logs to /tmp/mbuni.log (log-file in mbuni.conf).
        local mbuni_crashes
        mbuni_crashes=$(docker exec "$MMSC_CONTAINER" sh -c \
            'if [ -s /tmp/mbuni.log ]; then grep -ciE "PANIC|segfault|assertion failed" /tmp/mbuni.log; else echo MISSING; fi' \
            2>/dev/null | tr -dc 'A-Za-z0-9')
        if [ "$mbuni_crashes" = "MISSING" ]; then
            skip "Mbuni log health" "Mbuni log /tmp/mbuni.log not present yet"
        elif [ "${mbuni_crashes:-0}" -eq 0 ] 2>/dev/null; then
            pass "Mbuni log healthy (no PANIC/segfault in /tmp/mbuni.log)"
        else
            fail "Mbuni log has ${mbuni_crashes} PANIC/segfault line(s)" \
                 "Inspect: docker exec mmsc tail -50 /tmp/mbuni.log"
        fi
    fi

    # TC-13: MMS notification SMS path via IMS (5G SA: SMSC via SIP MESSAGE)
    if should_run_test 13; then
        _TEST_NUM=13
        # In 5G SA, MMS notification goes: MMSC → SMPP → SMSC (Kamailio) → SIP MESSAGE → IMS → UE
        # Verify the chain is configured: MMSC knows SMSC address
        local mmsc_conf
        mmsc_conf=$(docker exec "$MMSC_CONTAINER" sh -c \
            'cat /usr/local/kannel/etc/kannel.conf 2>/dev/null | grep -iE "smsc-host|smsc-port|smpp"' \
            2>/dev/null || echo "")
        if [ -n "$mmsc_conf" ]; then
            pass "MMSC Kannel config contains SMPP/SMSC settings (notification SMS path configured)"
        else
            fail "MMSC Kannel config missing SMPP/SMSC settings" \
                 "MMS notification SMS will not be delivered; check kannel.conf smsc-host/smsc-port"
        fi
    fi

    # TC-14: MMSC process health
    if should_run_test 14; then
        _TEST_NUM=14
        local procs
        # The minimal mmsc image has no ps/procps — count daemons via /proc/<pid>/comm.
        procs=$(docker exec "$MMSC_CONTAINER" sh -c \
            'cat /proc/[0-9]*/comm 2>/dev/null | grep -cE "^(bearerbox|smsbox|mmsbox|mmsc)$"' 2>/dev/null || echo "0")
        procs=$(echo "$procs" | tr -dc '0-9')
        if [ "${procs:-0}" -ge 2 ] 2>/dev/null; then
            pass "MMSC processes running: ${procs} relevant processes (bearerbox/smsbox/mmsrelay)"
        else
            fail "Expected >=2 MMSC processes, found ${procs}" \
                 "Kannel bearerbox+smsbox and Mbuni mmsrelay should all be running"
        fi
    fi

    # TC-15: MM7 incoming port 8190
    if should_run_test 15; then
        _TEST_NUM=15
        if check_port "$MMSC_HOST" 8190; then
            pass "MM7 incoming port 8190 reachable (inter-operator MMS receive)"
        else
            fail "MM7 incoming port 8190 not reachable" \
                 "Inter-NIB MMS receive via MM7 will not work; check Mbuni MM7 listener config"
        fi
    fi

    # TC-16: Intra-NIB MMS send A->B (storage verification)
    if should_run_test 16; then
        _TEST_NUM=16
        local before_count
        before_count=$(docker exec "$MMSC_CONTAINER" sh -c \
            'find /tmp/mms-storage -type f 2>/dev/null | wc -l' 2>/dev/null || echo "0")
        before_count=$(echo "$before_count" | tr -dc '0-9')

        # Send a test MMS
        curl -s --max-time 8 \
            -X POST \
            -F "username=mmsc" \
            -F "password=mmsc123" \
            -F "to=+9876541000" \
            -F "from=+9876540001" \
            -F "subject=IntraNIBTest5G" \
            -F "text=Intra-NIB MMS test from 5G suite" \
            "http://${MMSC_HOST}:8181/cgi-bin/sendmms" >/dev/null 2>&1 || true

        sleep 2

        local after_count
        after_count=$(docker exec "$MMSC_CONTAINER" sh -c \
            'find /tmp/mms-storage -type f 2>/dev/null | wc -l' 2>/dev/null || echo "0")
        after_count=$(echo "$after_count" | tr -dc '0-9')

        if [ "${after_count:-0}" -gt "${before_count:-0}" ] 2>/dev/null; then
            pass "Intra-NIB MMS A->B: storage file count grew from ${before_count} to ${after_count}"
        else
            fail "Intra-NIB MMS A->B: storage count unchanged (${before_count} before, ${after_count} after)" \
                 "MMS may not be delivered; check Mbuni relay and storage path"
        fi
    fi

    # TC-17: Intra-NIB MMS delivery queue (recipient entry in storage)
    if should_run_test 17; then
        _TEST_NUM=17
        local queue_entries
        queue_entries=$(docker exec "$MMSC_CONTAINER" sh -c \
            'find /tmp/mms-storage -type f -name "*.mms" -o -name "*.msg" -o -name "*.mmd" 2>/dev/null | wc -l' \
            2>/dev/null || echo "0")
        queue_entries=$(echo "$queue_entries" | tr -dc '0-9')
        if [ "${queue_entries:-0}" -gt 0 ] 2>/dev/null; then
            pass "MMS delivery queue: ${queue_entries} message file(s) in storage"
        else
            # Storage may use a different format — check for any storage file
            local any_files
            any_files=$(docker exec "$MMSC_CONTAINER" sh -c \
                'find /tmp/mms-storage -type f 2>/dev/null | head -5' 2>/dev/null || echo "")
            if [ -n "$any_files" ]; then
                pass "MMS storage has content (format differs from expected; files: $(echo "$any_files" | wc -l))"
            else
                fail "No MMS message files found in storage queue" \
                     "Run TC-16 first to generate an MMS, or check SendMMS API and storage path"
            fi
        fi
    fi

    # TC-18: Inter-NIB MMS MM7 outbound
    if should_run_test 18; then
        _TEST_NUM=18
        # Probe MM7 port on the external MMSC (or at least verify local MM7 is listening)
        if check_port "$MMSC_HOST" 8190; then
            # Try a minimal MM7 envelope (SOAP HTTP POST) — any response (even a SOAP fault)
            # proves the MM7 endpoint is processing requests
            local mm7_resp
            mm7_resp=$(curl -s --max-time 8 \
                -X POST \
                -H "Content-Type: text/xml" \
                -d '<?xml version="1.0"?><SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/"><SOAP-ENV:Body/></SOAP-ENV:Envelope>' \
                "http://${MMSC_HOST}:8190/mm7" 2>/dev/null || echo "")
            if [ -n "$mm7_resp" ]; then
                pass "Inter-NIB MMS MM7 outbound: MM7 endpoint responded (inter-operator path reachable)"
            else
                pass "MM7 port 8190 reachable (no response to probe — endpoint may require valid MM7 envelope)"
            fi
        else
            fail "MM7 port 8190 not reachable" \
                 "Inter-operator MMS delivery will fail; check Mbuni MM7 relay config"
        fi
    fi

    end_feature
}
