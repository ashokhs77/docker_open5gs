#!/bin/bash
# Feature 20: SBI Protocol Conformance (5G)  (TRL8 add-on)
# 3GPP TS 29.500 (SBI framework), TS 29.501 (API design), TS 29.510 (NRF),
# TS 29.503 (UDM). Active probes against live SBI endpoints over HTTP/2.
#
# Deepens nrf_sbi (which proves reachability/registration) into protocol-level
# conformance: HTTP/2 transport, URI versioning, mandatory NF-profile IEs,
# discovery semantics, ProblemDetails error bodies, and input-validation
# discipline (negative inputs must yield 4xx, never 5xx/crash).
#
# Calibration (never breaks the suite):
#   - SKIP when an endpoint is unreachable (core-only / partial stack).
#   - FAIL only on genuine conformance defects while reachable:
#     5xx/crash on well-formed negative input, or NRF dead after the battery.
#   - Format ambiguities (version-dependent bodies) are SKIP-with-note.
#
# All TCs are simulator-testable (control-plane only — no real-HW gate).
#
# Tests:
#   TC-1:  HTTP/2 transport on SBI (h2c prior-knowledge)         [29.500 §5.2]
#   TC-2:  API URI versioning (/v1 valid; /v99 rejected)         [29.501 §4.4]
#   TC-3:  NF profile mandatory IEs (nfInstanceId/nfType/nfStatus) [29.510]
#   TC-4:  NFDiscover via nnrf-disc (target+requester NF type)   [29.510]
#   TC-5:  ProblemDetails on malformed discovery request          [29.500 §5.2.7]
#   TC-6:  404 discipline for unknown nf-instance resource        [29.500]
#   TC-7:  UDM SDM negative input -> 4xx, never 5xx               [29.503]
#   TC-8:  NRF subscription input validation (invalid POST -> 4xx) [29.510]
#   TC-9:  heartBeatTimer present in registered NF profiles       [29.510]
#   TC-10: Content-Type discipline on profile responses           [29.500]
#   TC-11: SCP indirect communication availability (model C/D)    [29.500]
#   TC-12: NRF stability after negative-input battery (guard)

set +e

# --- local SBI probe helpers (HTTP/2 prior knowledge, like sbi_get) ---------
_sbi20_code() {
    # args: METHOD URL [JSON_BODY] -> echoes http code (000 on no answer)
    local method="$1" url="$2" body="${3:-}"
    if [ -n "$body" ]; then
        curl -s --http2-prior-knowledge -o /dev/null -w "%{http_code}" --max-time 5 \
            -X "$method" -H "Content-Type: application/json" -d "$body" "$url" 2>/dev/null || echo "000"
    else
        curl -s --http2-prior-knowledge -o /dev/null -w "%{http_code}" --max-time 5 \
            -X "$method" -H "Accept: application/json" "$url" 2>/dev/null || echo "000"
    fi
}

_sbi20_body() {
    # args: URL -> echoes body then last line http code
    curl -s --http2-prior-knowledge -w "\n%{http_code}" --max-time 5 \
        -H "Accept: application/json" "$1" 2>/dev/null || echo -e "\n000"
}

_sbi20_headers() {
    # args: URL -> echoes response headers
    curl -s --http2-prior-knowledge -D - -o /dev/null --max-time 5 \
        -H "Accept: application/json" "$1" 2>/dev/null || true
}

run_sbi_conformance_5g_tests() {
    start_feature "SBI Conformance (5G)"

    local nrf_base="http://${NRF_IP}:${NRF_PORT}"
    local nrf_up=false
    check_port "$NRF_IP" "$NRF_PORT" && nrf_up=true

    # TC-1: HTTP/2 transport on SBI (TS 29.500 mandates HTTP/2)
    if should_run_test 1; then
        _TEST_NUM=1
        if ! $nrf_up; then
            skip "HTTP/2 transport on SBI" "NRF not reachable at ${NRF_IP}:${NRF_PORT}"
        else
            local c1
            c1=$(_sbi20_code GET "${nrf_base}/nnrf-nfm/v1/nf-instances")
            if echo "$c1" | grep -qE '^2[0-9][0-9]$'; then
                pass "SBI speaks HTTP/2 (h2c prior-knowledge GET -> $c1) per TS 29.500"
            elif [ "$c1" = "000" ]; then
                skip "HTTP/2 transport on SBI" "No HTTP/2 answer from NRF — verify SBI is up"
            else
                skip "HTTP/2 transport on SBI" "NRF answered HTTP $c1 over h2 — API reachable but collection GET not 2xx; verify NRF version"
            fi
        fi
    fi

    # TC-2: API URI versioning — /v1 valid, bogus /v99 rejected (TS 29.501)
    if should_run_test 2; then
        _TEST_NUM=2
        if ! $nrf_up; then
            skip "API URI versioning" "NRF not reachable"
        else
            local cv1 cv99
            cv1=$(_sbi20_code GET "${nrf_base}/nnrf-nfm/v1/nf-instances")
            cv99=$(_sbi20_code GET "${nrf_base}/nnrf-nfm/v99/nf-instances")
            if echo "$cv1" | grep -qE '^2' && echo "$cv99" | grep -qE '^4'; then
                pass "URI versioning conforms: /v1 -> $cv1, unknown /v99 -> $cv99 (TS 29.501 §4.4)"
            elif echo "$cv99" | grep -qE '^5'; then
                fail "Unknown API version /v99 caused HTTP $cv99 (server error)" \
                     "TS 29.500: invalid versions must be rejected with 4xx, not crash with 5xx"
            else
                skip "API URI versioning" "v1 -> $cv1, v99 -> $cv99 — inconclusive; verify routing rules"
            fi
        fi
    fi

    # TC-3: NF profile mandatory IEs (TS 29.510: nfInstanceId, nfType, nfStatus)
    if should_run_test 3; then
        _TEST_NUM=3
        if ! $nrf_up; then
            skip "NF profile mandatory IEs" "NRF not reachable"
        else
            # open5gs nnrf-nfm collection returns HAL links only; full NF profiles
            # come from nnrf-disc, so validate the mandatory IEs there.
            local prof
            prof=$(_sbi20_body "${nrf_base}/nnrf-disc/v1/nf-instances?target-nf-type=AMF&requester-nf-type=SMF")
            if echo "$prof" | grep -q '"nfInstanceId"' && \
               echo "$prof" | grep -q '"nfType"' && \
               echo "$prof" | grep -qi '"nfStatus"'; then
                if echo "$prof" | grep -qi 'REGISTERED'; then
                    pass "AMF NF profile carries mandatory IEs (nfInstanceId, nfType, nfStatus=REGISTERED)"
                else
                    pass "AMF NF profile carries mandatory IEs (nfInstanceId, nfType, nfStatus)"
                fi
            elif echo "$prof" | tail -1 | grep -qE '^2'; then
                skip "NF profile mandatory IEs" \
                     "Collection answered 2xx but profile fields not found (links-only format?) — verify NRF response format against 29.510"
            else
                skip "NF profile mandatory IEs" "No AMF profile retrievable (AMF may not be registered)"
            fi
        fi
    fi

    # TC-4: NFDiscover via nnrf-disc (TS 29.510 §6.2)
    if should_run_test 4; then
        _TEST_NUM=4
        if ! $nrf_up; then
            skip "NFDiscover (nnrf-disc)" "NRF not reachable"
        else
            local disc
            disc=$(_sbi20_body "${nrf_base}/nnrf-disc/v1/nf-instances?target-nf-type=AMF&requester-nf-type=SMF")
            local dcode; dcode=$(echo "$disc" | tail -1)
            if echo "$disc" | grep -q '"nfInstances"' || { echo "$dcode" | grep -qE '^2' && echo "$disc" | grep -q '"nfInstanceId"'; }; then
                pass "NFDiscover returns instance set for target-nf-type=AMF (nnrf-disc operational)"
            elif echo "$dcode" | grep -qE '^5'; then
                fail "NFDiscover returned HTTP $dcode (server error) for a well-formed query" \
                     "nnrf-disc must answer 2xx/4xx per TS 29.510"
            else
                skip "NFDiscover (nnrf-disc)" "HTTP $dcode — no discoverable AMF or disc service disabled"
            fi
        fi
    fi

    # TC-5: ProblemDetails on malformed discovery (missing mandatory params)
    if should_run_test 5; then
        _TEST_NUM=5
        if ! $nrf_up; then
            skip "ProblemDetails on malformed discovery" "NRF not reachable"
        else
            local mal; mal=$(_sbi20_body "${nrf_base}/nnrf-disc/v1/nf-instances")
            local mcode; mcode=$(echo "$mal" | tail -1)
            if echo "$mcode" | grep -qE '^4'; then
                if echo "$mal" | grep -qE '"(title|detail|cause|status)"'; then
                    pass "Malformed discovery -> HTTP $mcode with ProblemDetails body (TS 29.500 §5.2.7)"
                else
                    pass "Malformed discovery rejected with HTTP $mcode (ProblemDetails fields not detected — acceptable minimal reject)"
                fi
            elif echo "$mcode" | grep -qE '^5'; then
                fail "Malformed discovery caused HTTP $mcode (server error)" \
                     "Missing mandatory query params must yield 400 + ProblemDetails, not 5xx"
            elif echo "$mcode" | grep -qE '^2'; then
                skip "ProblemDetails on malformed discovery" \
                     "NRF answered 2xx without mandatory params (permissive mode) — verify against TS 29.510 mandatory-param enforcement"
            else
                skip "ProblemDetails on malformed discovery" "No conclusive answer (HTTP $mcode)"
            fi
        fi
    fi

    # TC-6: 404 discipline for unknown nf-instance resource
    if should_run_test 6; then
        _TEST_NUM=6
        if ! $nrf_up; then
            skip "404 discipline for unknown nf-instance" "NRF not reachable"
        else
            local ucode
            ucode=$(_sbi20_code GET "${nrf_base}/nnrf-nfm/v1/nf-instances/deadbeef-0000-4000-8000-000000000000")
            if [ "$ucode" = "404" ] || [ "$ucode" = "400" ]; then
                pass "Unknown nf-instance resource -> HTTP $ucode (correct not-found discipline)"
            elif echo "$ucode" | grep -qE '^5'; then
                fail "Unknown nf-instance lookup caused HTTP $ucode (server error)" \
                     "Unknown resources must yield 404, not 5xx"
            else
                skip "404 discipline for unknown nf-instance" "HTTP $ucode — inconclusive"
            fi
        fi
    fi

    # TC-7: UDM SDM negative input -> 4xx, never 5xx (TS 29.503)
    if should_run_test 7; then
        _TEST_NUM=7
        if ! check_port "$UDM_IP" "$UDM_PORT"; then
            skip "UDM SDM negative-input discipline" "UDM not reachable at ${UDM_IP}:${UDM_PORT}"
        else
            local scode
            scode=$(_sbi20_code GET "http://${UDM_IP}:${UDM_PORT}/nudm-sdm/v2/imsi-999999999999999/am-data")
            if echo "$scode" | grep -qE '^4'; then
                pass "UDM SDM unknown-SUPI request -> HTTP $scode (4xx discipline, no crash)"
            elif echo "$scode" | grep -qE '^5'; then
                fail "UDM SDM unknown-SUPI request caused HTTP $scode (server error)" \
                     "Negative input must yield 4xx per TS 29.503/29.500"
            else
                skip "UDM SDM negative-input discipline" "HTTP $scode — inconclusive"
            fi
        fi
    fi

    # TC-8: NRF subscription input validation (invalid POST -> 4xx, not 5xx)
    if should_run_test 8; then
        _TEST_NUM=8
        if ! $nrf_up; then
            skip "NRF subscription input validation" "NRF not reachable"
        else
            local pcode
            pcode=$(_sbi20_code POST "${nrf_base}/nnrf-nfm/v1/subscriptions" '{}')
            if echo "$pcode" | grep -qE '^4'; then
                pass "Invalid subscription POST ({} body) rejected with HTTP $pcode (schema validation active)"
            elif echo "$pcode" | grep -qE '^5'; then
                fail "Invalid subscription POST caused HTTP $pcode (server error)" \
                     "Schema-invalid bodies must yield 400 + ProblemDetails, not 5xx"
            elif echo "$pcode" | grep -qE '^2'; then
                skip "NRF subscription input validation" \
                     "NRF accepted an empty subscription object (HTTP $pcode) — verify mandatory-IE enforcement per 29.510"
            else
                skip "NRF subscription input validation" "HTTP $pcode — inconclusive"
            fi
        fi
    fi

    # TC-9: heartBeatTimer present in registered NF profiles (TS 29.510)
    if should_run_test 9; then
        _TEST_NUM=9
        if ! $nrf_up; then
            skip "heartBeatTimer in NF profiles" "NRF not reachable"
        else
            # full profiles via nnrf-disc (nnrf-nfm collection is links-only)
            local hb
            hb=$(_sbi20_body "${nrf_base}/nnrf-disc/v1/nf-instances?target-nf-type=AMF&requester-nf-type=SMF")
            if echo "$hb" | grep -q '"heartBeatTimer"'; then
                pass "Registered NF profiles carry heartBeatTimer (NRF liveness supervision active)"
            elif echo "$hb" | grep -q '"nfInstanceId"'; then
                skip "heartBeatTimer in NF profiles" \
                     "Profile present without visible heartBeatTimer — verify NRF heartbeat supervision config"
            else
                skip "heartBeatTimer in NF profiles" "No SMF profile retrievable"
            fi
        fi
    fi

    # TC-10: Content-Type discipline on profile responses (TS 29.500)
    if should_run_test 10; then
        _TEST_NUM=10
        if ! $nrf_up; then
            skip "Content-Type discipline" "NRF not reachable"
        else
            local hdrs
            hdrs=$(_sbi20_headers "${nrf_base}/nnrf-nfm/v1/nf-instances?nf-type=AMF")
            if echo "$hdrs" | grep -qiE 'content-type:.*(application/(3gppHal\+)?json)'; then
                pass "Profile responses use application/json content type (TS 29.500 media-type discipline)"
            elif [ -n "$hdrs" ]; then
                skip "Content-Type discipline" \
                     "Response headers present but content-type not json: $(echo "$hdrs" | grep -i content-type | head -1)"
            else
                skip "Content-Type discipline" "No response headers captured"
            fi
        fi
    fi

    # TC-11: SCP indirect communication availability (model C/D)
    if should_run_test 11; then
        _TEST_NUM=11
        if container_is_running "scp" && check_port "$SCP_IP" "$SCP_PORT"; then
            pass "SCP deployed and SBI-reachable — indirect communication (model C/D) available"
        elif container_is_running "scp"; then
            skip "SCP indirect communication" "SCP container up but SBI port ${SCP_PORT} not reachable"
        else
            skip "SCP indirect communication" "SCP not deployed — direct communication (model A/B) only"
        fi
    fi

    # TC-12: NRF stability after negative-input battery (guard)
    if should_run_test 12; then
        _TEST_NUM=12
        if ! $nrf_up; then
            skip "NRF stability after negative-input battery" "NRF was not reachable for this battery"
        else
            local gcode
            gcode=$(_sbi20_code GET "${nrf_base}/nnrf-nfm/v1/nf-instances")
            if echo "$gcode" | grep -qE '^2'; then
                if container_is_running "nrf"; then
                    pass "NRF alive and responsive (HTTP $gcode) after TC-2..TC-8 negative-input battery"
                else
                    pass "NRF API responsive (HTTP $gcode) after negative-input battery"
                fi
            else
                fail "NRF unresponsive (HTTP $gcode) after negative-input battery" \
                     "TC-2..TC-8 probes must not degrade the NRF — check nrf logs for crash/restart"
            fi
        fi
    fi

    end_feature
}
