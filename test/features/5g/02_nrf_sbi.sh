#!/bin/bash
# Feature 02: NRF & SBI Interface Health
# Validates the 5G Service Based Interface: NRF discovery, NF registration,
# and SCP proxy. All 5G NFs register with the NRF on startup; missing
# registrations indicate NF startup failures or NRF unreachability.
#
# Tests:
#   TC-1:  NRF SBI port 7777 reachable
#   TC-2:  NRF nf-instances API accessible (HTTP 200)
#   TC-3:  AMF registered with NRF
#   TC-4:  SMF registered with NRF
#   TC-5:  AUSF registered with NRF
#   TC-6:  UDM registered with NRF
#   TC-7:  PCF registered with NRF
#   TC-8:  NSSF registered with NRF
#   TC-9:  BSF registered with NRF
#   TC-10: SCP SBI port reachable

set +e

run_nrf_sbi_tests() {
    start_feature "NRF & SBI"

    # TC-1: NRF SBI port reachable
    if should_run_test 1; then
        _TEST_NUM=1
        if check_port "$NRF_IP" "$NRF_PORT"; then
            pass "NRF SBI port ${NRF_PORT} reachable at ${NRF_IP}"
        else
            fail "NRF SBI port ${NRF_PORT} not reachable" \
                 "NRF at ${NRF_IP} is unreachable; all NF registration checks will fail"
        fi
    fi

    # TC-2: NRF nf-instances API
    if should_run_test 2; then
        _TEST_NUM=2
        local nrf_resp
        nrf_resp=$(curl -s --http2-prior-knowledge -o /dev/null -w "%{http_code}" \
            --max-time 5 \
            "http://${NRF_IP}:${NRF_PORT}/nnrf-nfm/v1/nf-instances" 2>/dev/null || echo "000")
        if [ "$nrf_resp" = "200" ] || [ "$nrf_resp" = "204" ]; then
            pass "NRF nnrf-nfm/v1/nf-instances API returned HTTP ${nrf_resp}"
        else
            fail "NRF nf-instances API returned HTTP ${nrf_resp}" \
                 "Expected 200/204; check NRF startup and MongoDB connectivity"
        fi
    fi

    # Helper: check if a given NF type is registered in NRF
    check_nrf_registration() {
        local nf_type="$1"
        local resp
        resp=$(curl -s --http2-prior-knowledge --max-time 5 \
            "http://${NRF_IP}:${NRF_PORT}/nnrf-nfm/v1/nf-instances?nf-type=${nf_type}" 2>/dev/null || echo "")
        # NRF returns a SearchResult with nfInstances array; non-empty means registered
        if echo "$resp" | grep -qiE '"href"|"totalItemCount"'; then
            return 0
        fi
        return 1
    }

    # TC-3: AMF registered with NRF
    if should_run_test 3; then
        _TEST_NUM=3
        if check_nrf_registration "AMF"; then
            pass "AMF registered with NRF"
        else
            fail "AMF not found in NRF nf-instances" \
                 "AMF may still be starting up or failed NRF registration; check AMF logs"
        fi
    fi

    # TC-4: SMF registered with NRF
    if should_run_test 4; then
        _TEST_NUM=4
        if check_nrf_registration "SMF"; then
            pass "SMF registered with NRF"
        else
            fail "SMF not found in NRF nf-instances" \
                 "Check SMF logs for NRF registration errors"
        fi
    fi

    # TC-5: AUSF registered with NRF
    if should_run_test 5; then
        _TEST_NUM=5
        if check_nrf_registration "AUSF"; then
            pass "AUSF registered with NRF"
        else
            fail "AUSF not found in NRF nf-instances" \
                 "Check AUSF logs for NRF registration errors"
        fi
    fi

    # TC-6: UDM registered with NRF
    if should_run_test 6; then
        _TEST_NUM=6
        if check_nrf_registration "UDM"; then
            pass "UDM registered with NRF"
        else
            fail "UDM not found in NRF nf-instances" \
                 "Check UDM logs for NRF registration errors"
        fi
    fi

    # TC-7: PCF registered with NRF
    if should_run_test 7; then
        _TEST_NUM=7
        if check_nrf_registration "PCF"; then
            pass "PCF registered with NRF"
        else
            fail "PCF not found in NRF nf-instances" \
                 "Check PCF logs for NRF registration errors"
        fi
    fi

    # TC-8: NSSF registered with NRF
    if should_run_test 8; then
        _TEST_NUM=8
        if check_nrf_registration "NSSF"; then
            pass "NSSF registered with NRF"
        else
            fail "NSSF not found in NRF nf-instances" \
                 "Check NSSF logs for NRF registration errors"
        fi
    fi

    # TC-9: BSF registered with NRF
    if should_run_test 9; then
        _TEST_NUM=9
        if check_nrf_registration "BSF"; then
            pass "BSF registered with NRF"
        else
            fail "BSF not found in NRF nf-instances" \
                 "Check BSF logs for NRF registration errors"
        fi
    fi

    # TC-10: SCP SBI port reachable
    if should_run_test 10; then
        _TEST_NUM=10
        if check_port "$SCP_IP" "$SCP_PORT"; then
            pass "SCP SBI port ${SCP_PORT} reachable at ${SCP_IP}"
        else
            fail "SCP SBI port ${SCP_PORT} not reachable" \
                 "SCP is used as proxy for inter-NF communications; check SCP container"
        fi
    fi

    end_feature
}
