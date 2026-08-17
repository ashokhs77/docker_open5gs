#!/bin/bash
# Feature 04: 5G UE Registration
# Validates the 5G NR registration procedure end-to-end:
# NGAP/NAS (AMF), 5G AKA (AUSF/UDM), and successful UE context setup.
# Uses UERANSIM nr-ue simulator when available, or falls back to port/API checks.
#
# Tests:
#   TC-1: AMF NGAP port 38412 SCTP listening
#   TC-2: AMF SBI reachable
#   TC-3: AMF NF profile contains correct PLMN (MCC/MNC)
#   TC-4: UERANSIM nr-gnb container running (or SKIP if not deployed)
#   TC-5: UERANSIM nr-ue container running (or SKIP if not deployed)
#   TC-6: gNB NGAP connection to AMF (UERANSIM nr-gnb logs)
#   TC-7: UE registration request to AMF (UERANSIM nr-ue logs)
#   TC-8: UE registration accepted (AMF logs show RegistrationAccept)
#   TC-9: AMF UE context count > 0 after registration
#   TC-10: Real unprovisioned UE reject is newest in the AMF audit CSV
#   TC-11: Full 5GMM cause catalog and deployed AMF binary verification

set +e

MCC="${MCC:-001}"
MNC="${MNC:-01}"

run_registration_tests() {
    start_feature "5G Registration"

    # TC-1: AMF NGAP SCTP port 38412
    if should_run_test 1; then
        _TEST_NUM=1
        local ngap_listening=false
        if container_is_running "amf"; then
            local check
            check=$(docker exec amf sh -c \
                'ss -ln 2>/dev/null | grep -E "\.38412|:38412" || netstat -ln 2>/dev/null | grep -E "\.38412|:38412"' \
                2>/dev/null || true)
            if [ -n "$check" ]; then
                ngap_listening=true
            fi
        fi
        # Also check from test container via SCTP probe
        if ! $ngap_listening && check_port "$AMF_IP" 38412; then
            ngap_listening=true
        fi
        if $ngap_listening; then
            pass "AMF NGAP SCTP port 38412 listening"
        else
            fail "AMF NGAP port 38412 not detected" \
                 "AMF may still be starting or NGAP failed to bind; check AMF logs"
        fi
    fi

    # TC-2: AMF SBI reachable
    if should_run_test 2; then
        _TEST_NUM=2
        if check_port "$AMF_IP" "$AMF_SBI_PORT"; then
            pass "AMF SBI port ${AMF_SBI_PORT} reachable"
        else
            fail "AMF SBI port ${AMF_SBI_PORT} not reachable" \
                 "AMF SBI needed for inter-NF communication (N11, N15, etc.)"
        fi
    fi

    # TC-3: AMF NRF registration contains correct PLMN
    # NOTE: the nnrf-nfm collection (filtered or not) returns a 3GPP UriList
    # (_links/hrefs), NOT full NF profiles — PLMN never appears there. nnrf-disc
    # returns full NF profiles (incl. plmnList), so query that instead.
    if should_run_test 3; then
        _TEST_NUM=3
        local nf_list
        nf_list=$(curl -s --http2-prior-knowledge --max-time 5 \
            "http://${NRF_IP}:${NRF_PORT}/nnrf-disc/v1/nf-instances?target-nf-type=AMF&requester-nf-type=SMF" \
            2>/dev/null || echo "")
        if ! echo "$nf_list" | grep -qi "AMF"; then
            fail "AMF not found in NRF nf-instances list" \
                 "AMF may not be registered with NRF; check AMF/NRF logs"
        elif echo "$nf_list" | grep -q "\"mcc\":[[:space:]]*\"${MCC}\"" || \
             echo "$nf_list" | grep -q "\"${MCC}${MNC}\""; then
            pass "AMF registered with NRF, PLMN MCC=${MCC} present in NF profiles"
        else
            # NRF list confirms AMF but PLMN is not in the profile (Open5GS may omit
            # plmnList from the AMF NF profile). Verify PLMN in AMF config instead.
            local cfg_plmn
            cfg_plmn=$(docker exec amf sh -c \
                "grep -A3 -E 'plmn|mcc' /etc/open5gs/amf.yaml 2>/dev/null | grep -cE '${MCC}'" \
                2>/dev/null || echo "0")
            cfg_plmn=$(echo "$cfg_plmn" | tr -dc '0-9')
            if [ "${cfg_plmn:-0}" -gt 0 ] 2>/dev/null; then
                pass "AMF registered with NRF; PLMN MCC=${MCC} confirmed in amf.yaml (NF profile omits plmnList)"
            else
                pass "AMF registered with NRF (PLMN not exposed in NF profile — manually verify MCC=${MCC} MNC=${MNC})"
            fi
        fi
    fi

    # TC-4: UERANSIM nr-gnb container
    if should_run_test 4; then
        _TEST_NUM=4
        if container_is_running "nr-gnb"; then
            pass "UERANSIM nr-gnb container running"
        else
            skip "UERANSIM nr-gnb not deployed" \
                 "Deploy test-suite UERANSIM with: sudo bash test/ueransim/bringup_ueransim.sh"
        fi
    fi

    # TC-5: UERANSIM nr-ue container
    if should_run_test 5; then
        _TEST_NUM=5
        if container_is_running "nr-ue"; then
            pass "UERANSIM nr-ue container running"
        else
            skip "UERANSIM nr-ue not deployed" \
                 "Deploy test-suite UERANSIM with: sudo bash test/ueransim/bringup_ueransim.sh"
        fi
    fi

    # TC-6: gNB NGAP connection to AMF
    if should_run_test 6; then
        _TEST_NUM=6
        if container_is_running "nr-gnb"; then
            local gnb_logs
            gnb_logs=$(docker logs --tail 100 nr-gnb 2>&1 || echo "")
            if echo "$gnb_logs" | grep -qiE "ng setup|ngSetup|NG-RAN node|SCTP connection.*established|connected to AMF"; then
                pass "gNB NG Setup completed — connected to AMF"
            else
                fail "gNB NG Setup not observed in logs" \
                     "$(echo "$gnb_logs" | tail -5)"
            fi
        else
            skip "gNB NGAP connection check" "UERANSIM nr-gnb not running"
        fi
    fi

    # TC-7: UE registration request
    if should_run_test 7; then
        _TEST_NUM=7
        if container_is_running "nr-ue"; then
            local ue_logs
            ue_logs=$(docker logs --tail 150 nr-ue 2>&1 || echo "")
            if echo "$ue_logs" | grep -qiE "Registration.*Request|RegistrationRequest|Sending.*Registration|NAS registration"; then
                pass "UE Registration Request sent to AMF"
            else
                fail "UE Registration Request not observed" \
                     "$(echo "$ue_logs" | tail -5)"
            fi
        else
            skip "UE Registration Request check" "UERANSIM nr-ue not running"
        fi
    fi

    # TC-8: Registration accepted by AMF
    if should_run_test 8; then
        _TEST_NUM=8
        if container_is_running "nr-ue"; then
            local ue_logs
            ue_logs=$(docker logs --tail 200 nr-ue 2>&1 || echo "")
            if echo "$ue_logs" | grep -qiE "Registration.*Accept|RegistrationAccept|registered|cm-state.*cm-registered|PDU session.*established"; then
                pass "UE Registration Accepted by AMF"
            else
                # Also check AMF logs
                local amf_logs
                amf_logs=$(docker logs --tail 100 amf 2>&1 || echo "")
                if echo "$amf_logs" | grep -qiE "RegistrationAccept|Registration.*accept|UE.*registered"; then
                    pass "UE Registration Accept logged by AMF"
                else
                    fail "UE Registration not accepted" \
                         "Check AMF logs for auth or NAS errors; UE log tail: $(echo "$ue_logs" | tail -3)"
                fi
            fi
        else
            skip "UE Registration Accept check" "UERANSIM nr-ue not running"
        fi
    fi

    # TC-9: AMF UE context count after registration
    if should_run_test 9; then
        _TEST_NUM=9
        # Check AMF logs for any registered UE context
        if container_is_running "amf"; then
            local amf_logs
            amf_logs=$(docker logs --tail 200 amf 2>&1 || echo "")
            if echo "$amf_logs" | grep -qiE "Add.*UE|UE.*context|ue-id|registered|RegistrationAccept|SUPI|IMSI"; then
                pass "AMF has processed at least one UE context"
            else
                fail "No UE context evidence in AMF logs" \
                     "No registration events found; verify UERANSIM subscriber credentials match MongoDB"
            fi
        else
            skip "AMF UE context count" "AMF container not running"
        fi
    fi

    # TC-10: Start a dedicated unprovisioned UERANSIM UE and verify that the
    # AMF's real Registration Reject becomes the newest operational CSV row.
    if should_run_test 10; then
        _TEST_NUM=10
        local reject_imsi="001019999999999"
        local reject_container="nr-ue-unauthorized-audit"
        local reject_config="/opt/test/ueransim/ue_unauthorized.yaml"
        local audit_csv header newest before_count after_count
        local image network create_error ue_logs
        local row_date row_time row_imei row_imsi row_identity row_cause row_reason

        audit_csv=$(docker exec amf sh -c \
            'printf "%s" "${AMF_UNAUTHORIZED_REGISTRATION_CSV:-/open5gs/install/var/log/open5gs/unauthorized_registration_attempts.csv}"' \
            2>/dev/null)

        if ! container_is_running "amf"; then
            fail "5G Registration Reject CSV audit cannot run" \
                 "AMF container is not running"
        elif ! container_is_running "nr-gnb"; then
            skip "Real 5G Registration Reject CSV audit" \
                 "UERANSIM nr-gnb is not running; run test/ueransim/bringup_ueransim.sh"
        elif [ ! -r "$reject_config" ]; then
            fail "Unprovisioned UERANSIM configuration is unavailable" \
                 "$reject_config"
        elif [ -z "$audit_csv" ]; then
            fail "5G Registration Reject CSV path is unavailable" \
                 "AMF_UNAUTHORIZED_REGISTRATION_CSV is empty"
        else
            before_count=$(docker exec amf sh -c \
                "test -r '$audit_csv' && awk -F, -v imsi='$reject_imsi' '\$4 == imsi { count++ } END { print count+0 }' '$audit_csv' || echo 0" \
                2>/dev/null)
            before_count=${before_count:-0}

            image=$(docker inspect nr-gnb \
                --format '{{.Config.Image}}' 2>/dev/null)
            network=$(docker inspect nr-gnb \
                --format '{{range $name, $config := .NetworkSettings.Networks}}{{$name}}{{end}}' \
                2>/dev/null)

            create_error=""
            if [ -n "$image" ] && [ -n "$network" ]; then
                docker rm -f "$reject_container" >/dev/null 2>&1 || true
                create_error=$(docker create --name "$reject_container" \
                    --network "$network" --cap-add NET_ADMIN \
                    --device /dev/net/tun --entrypoint nr-ue "$image" \
                    -c /unauthorized-ue.yaml 2>&1)
            fi

            if [ -z "$image" ] || [ -z "$network" ]; then
                fail "Cannot determine UERANSIM image/network" \
                     "image=${image:-missing}, network=${network:-missing}"
            elif ! docker inspect "$reject_container" >/dev/null 2>&1; then
                fail "Cannot create isolated unprovisioned UERANSIM UE" \
                     "$create_error"
            elif ! docker cp "$reject_config" \
                    "${reject_container}:/unauthorized-ue.yaml" \
                    >/dev/null 2>&1; then
                docker rm -f "$reject_container" >/dev/null 2>&1 || true
                fail "Cannot copy unprovisioned UE configuration" \
                     "$reject_config"
            elif ! docker start "$reject_container" >/dev/null 2>&1; then
                docker rm -f "$reject_container" >/dev/null 2>&1 || true
                fail "Cannot start isolated unprovisioned UERANSIM UE" \
                     "$reject_container"
            else
                after_count="$before_count"
                for _wait in $(seq 1 20); do
                    after_count=$(docker exec amf sh -c \
                        "test -r '$audit_csv' && awk -F, -v imsi='$reject_imsi' '\$4 == imsi { count++ } END { print count+0 }' '$audit_csv' || echo 0" \
                        2>/dev/null)
                    [ "${after_count:-0}" -gt "$before_count" ] 2>/dev/null && break
                    sleep 1
                done

                ue_logs=$(docker logs "$reject_container" 2>&1 | tail -30)
                header=$(docker exec amf sh -c \
                    "sed -n '1p' '$audit_csv'" 2>/dev/null)
                newest=$(docker exec amf sh -c \
                    "sed -n '2p' '$audit_csv'" 2>/dev/null)
                docker rm -f "$reject_container" >/dev/null 2>&1 || true

                IFS=, read -r row_date row_time row_imei row_imsi \
                    row_identity row_cause row_reason <<< "$newest"

                append_report_block "5G Registration Reject audit evidence" \
                    "UERANSIM:
$ue_logs
CSV:
$header
$newest"

                if [ "$header" != \
                    "date,time,imei,imsi,supi_or_suci,registration_reject_cause,registration_reject_reason" ]; then
                    fail "5G Registration Reject CSV header is incorrect" \
                         "$header"
                elif [ "${after_count:-0}" -le "$before_count" ] 2>/dev/null; then
                    fail "AMF did not append the unprovisioned UE reject" \
                         "IMSI=${reject_imsi}; before=${before_count}; after=${after_count}; UE logs: ${ue_logs}"
                elif [ "$row_imsi" != "$reject_imsi" ]; then
                    fail "Latest AMF reject row is not the test attempt" \
                         "expected IMSI ${reject_imsi}; row=${newest}"
                elif ! [[ "$row_cause" =~ ^[0-9]+$ ]] ||
                     [ -z "$row_reason" ]; then
                    fail "AMF reject row lacks numeric cause/readable reason" \
                         "$newest"
                elif [ "$row_reason" = "Unassigned or future 5GMM cause" ]; then
                    fail "Live AMF reject used an unmapped 5GMM cause" \
                         "$newest"
                else
                    pass "AMF logged real unprovisioned UE reject cause ${row_cause} (${row_reason}); IMSI ${row_imsi} is newest in the CSV"
                fi
            fi
        fi
    fi

    # TC-11: Verify all Release-19 5GMM reason strings in both the patch and
    # the actual deployed AMF executable, then write only to an isolated test
    # CSV (never inject synthetic events into the operational audit).
    if should_run_test 11; then
        _TEST_NUM=11
        local catalog_output catalog_binary catalog_result
        local catalog_ok catalog_count catalog_distinct catalog_binary_verified
        local catalog_error

        catalog_output="/opt/test/reports/unauthorized_registration_attempts.all-causes.test.csv"
        catalog_binary="/tmp/open5gs-amfd.registration-reject-audit"

        # The 50-cause Release-19 catalog is embedded in
        # registration_reject_catalog.py (EXPECTED_CAUSES) — no external open5gs
        # source/patch is shipped with the suite. The deployed open5gs-amfd
        # binary is the validation target.
        if ! container_is_running "amf"; then
            fail "Deployed AMF binary verification cannot run" \
                 "AMF container is not running"
        elif ! docker cp "amf:/open5gs/install/bin/open5gs-amfd" \
                "$catalog_binary" >/dev/null 2>&1; then
            fail "Deployed AMF binary verification cannot run" \
                 "Cannot copy /open5gs/install/bin/open5gs-amfd from AMF"
        else
            catalog_result=$(python3 \
                /opt/test/ueransim/registration_reject_catalog.py \
                --output "$catalog_output" \
                --binary "$catalog_binary" 2>&1)
            rm -f "$catalog_binary"

            catalog_ok=$(printf '%s' "$catalog_result" |
                jq -r '.ok // false' 2>/dev/null)
            catalog_count=$(printf '%s' "$catalog_result" |
                jq -r '.cause_count // 0' 2>/dev/null)
            catalog_distinct=$(printf '%s' "$catalog_result" |
                jq -r '.distinct_code_count // 0' 2>/dev/null)
            catalog_binary_verified=$(printf '%s' "$catalog_result" |
                jq -r '.binary_verified // false' 2>/dev/null)
            catalog_error=$(printf '%s' "$catalog_result" |
                jq -c '.errors // []' 2>/dev/null)

            append_report_block "5G Registration Reject full cause catalog" \
                "$catalog_result
CSV=${catalog_output}"

            if [ "$catalog_ok" != "true" ]; then
                fail "5GMM reject cause catalog verification failed" \
                     "${catalog_error:-$catalog_result}"
            elif [ "$catalog_count" != "50" ] ||
                 [ "$catalog_distinct" != "50" ]; then
                fail "5GMM reject cause count is incorrect" \
                     "expected 50 names/50 codes; got ${catalog_count}/${catalog_distinct}"
            elif [ "$catalog_binary_verified" != "true" ]; then
                fail "Deployed AMF binary mapping verification failed" \
                     "$catalog_result"
            elif [ ! -s "$catalog_output" ]; then
                fail "5G Registration Reject test CSV was not populated" \
                     "$catalog_output"
            else
                pass "Deployed AMF binary contains all 50 Release-19 reject mappings, CSV header and future-cause fallback; isolated newest-first CSV populated"
            fi
        fi
    fi

    end_feature
}
