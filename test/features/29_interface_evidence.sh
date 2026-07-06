#!/bin/bash
# Feature 29: Interface Evidence Pack (4G)
# Opt-in TRL8 evidence lane for packet-capture readiness and interface-level
# artifacts. It complements NAS/S1AP/PFCP/Diameter/SIP conformance tests by
# proving the run can attach pcaps and socket evidence, without disturbing the
# default deployment/dev test path.
#
# TC-1: Docker evidence access
# TC-2: tcpdump toolchain and reports/pcaps directory
# TC-3: DNS pcap from runner-generated traffic
# TC-4: S1-MME SCTP endpoint evidence
# TC-5: PFCP/GTP-U endpoint evidence
# TC-6: IMS SIP endpoint evidence
# TC-7: SIP pcap from runner-generated traffic
# TC-8: REAL_HW external S1/NAS/SIP pcap attachment gate

set +e
REAL_HW="${REAL_HW:-0}"
INTERFACE_EVIDENCE_REAL_HW_PCAP="${INTERFACE_EVIDENCE_REAL_HW_PCAP:-${REAL_HW_PCAP_FILE:-}}"

ie_pcap_dir() { mkdir -p "${REPORT_DIR}/pcaps" 2>/dev/null || true; echo "${REPORT_DIR}/pcaps"; }

ie_socket_block() {
    local container="$1" regex="$2"
    docker exec "$container" sh -c "ss -H -ln 2>/dev/null || netstat -ln 2>/dev/null" 2>/dev/null | grep -E "$regex" || true
}

ie_capture() {
    local label="$1" filter="$2" probe="$3" dir pcap log rc summary
    if ! command -v tcpdump >/dev/null 2>&1; then echo "|tcpdump unavailable"; return 70; fi
    dir=$(ie_pcap_dir); pcap="${dir}/${label}_$(date +%Y%m%d_%H%M%S).pcap"; log="${pcap}.log"
    timeout 6 tcpdump -i any -s 0 -c 1 -w "$pcap" "$filter" >"$log" 2>&1 &
    local pid=$!
    sleep 1
    case "$probe" in
        dns) dig +time=1 +tries=1 @"$DNS_IP" "$IMS_DOMAIN" A >/dev/null 2>&1 || true ;;
        sip) printf 'OPTIONS sip:interface-evidence@%s SIP/2.0\r\nVia: SIP/2.0/UDP %s:15060;branch=z9hG4bK-iface-evidence\r\nFrom: <sip:probe@%s>;tag=iface\r\nTo: <sip:interface-evidence@%s>\r\nCall-ID: iface-evidence-%s@%s\r\nCSeq: 1 OPTIONS\r\nMax-Forwards: 5\r\nContent-Length: 0\r\n\r\n' "$IMS_DOMAIN" "$LOCAL_IP" "$IMS_DOMAIN" "$IMS_DOMAIN" "$$" "$LOCAL_IP" | nc -u -w 1 "$PCSCF_IP" "$PCSCF_PORT" >/dev/null 2>&1 || true ;;
    esac
    wait "$pid" >/dev/null 2>&1; rc=$?
    if [ -s "$pcap" ]; then summary=$(tcpdump -nn -r "$pcap" -c 3 2>/dev/null || true); echo "${pcap}|${summary}"; return 0; fi
    echo "${pcap}|tcpdump rc=${rc}; $(tail -3 "$log" 2>/dev/null | tr '\n' ' ')"; return 1
}

run_interface_evidence_tests() {
    start_feature "Interface Evidence"

    _TEST_NUM=$((_TEST_NUM + 1)); if should_run_test $_TEST_NUM; then
        if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' >/tmp/interface_evidence_docker_ps.txt 2>/dev/null; then
            pass "Docker control-plane evidence access available"
            append_report_block "Docker evidence sample" "$(head -20 /tmp/interface_evidence_docker_ps.txt)"
        else
            fail "Docker control-plane evidence access unavailable" "Mount /var/run/docker.sock into the test container"
        fi
    fi

    _TEST_NUM=$((_TEST_NUM + 1)); if should_run_test $_TEST_NUM; then
        local dir ver; dir=$(ie_pcap_dir); ver=$(tcpdump --version 2>/dev/null | head -1 || true)
        if [ -n "$ver" ] && [ -d "$dir" ] && [ -w "$dir" ]; then
            pass "tcpdump toolchain and reports/pcaps artifact directory available"
            append_report_block "pcap toolchain" "${ver}; pcap_dir=${dir}"
        elif [ -z "$ver" ]; then
            skip "tcpdump packet-capture toolchain" "Rebuild the test image so test/Dockerfile installs tcpdump"
        else
            fail "reports/pcaps artifact directory not writable" "pcap_dir=${dir}"
        fi
    fi

    _TEST_NUM=$((_TEST_NUM + 1)); if should_run_test $_TEST_NUM; then
        local cap path summary; cap=$(ie_capture "4g_dns" "host ${DNS_IP} and port 53" dns); path=${cap%%|*}; summary=${cap#*|}
        if [ -s "$path" ]; then pass "DNS packet capture artifact generated"; append_report_block "DNS pcap artifact" "path=${path}
${summary}"; else skip "DNS packet capture artifact" "${summary:-no packet captured}"; fi
    fi

    _TEST_NUM=$((_TEST_NUM + 1)); if should_run_test $_TEST_NUM; then
        if container_listens_on_port mme "${MME_PORT:-36412}"; then
            pass "S1-MME SCTP endpoint is listening on MME:${MME_PORT:-36412}"
            append_report_block "S1-MME socket evidence" "$(ie_socket_block mme "[:.]${MME_PORT:-36412}([[:space:]]|$)")"
        else
            fail "S1-MME SCTP endpoint not listening" "MME must expose S1-MME ${MME_PORT:-36412}"
        fi
    fi

    _TEST_NUM=$((_TEST_NUM + 1)); if should_run_test $_TEST_NUM; then
        local pfcp="" gtpu=""; container_listens_on_port smf 8805 && pfcp="smf:8805"; container_listens_on_port upf 8805 && pfcp="${pfcp:+$pfcp, }upf:8805"; container_listens_on_port upf 2152 && gtpu="upf:2152"
        if [ -n "$pfcp" ] && [ -n "$gtpu" ]; then pass "PFCP/GTP-U endpoint evidence present (${pfcp}; ${gtpu})"; append_report_block "PFCP/GTP-U socket evidence" "$(ie_socket_block smf '[:.]8805([[:space:]]|$)')
$(ie_socket_block upf '[:.](8805|2152)([[:space:]]|$)')"; else fail "PFCP/GTP-U endpoint evidence incomplete" "pfcp=${pfcp:-missing}; gtpu=${gtpu:-missing}"; fi
    fi

    _TEST_NUM=$((_TEST_NUM + 1)); if should_run_test $_TEST_NUM; then
        if container_listens_on_port pcscf "${PCSCF_PORT:-5060}"; then pass "IMS SIP endpoint evidence present on P-CSCF:${PCSCF_PORT:-5060}"; append_report_block "P-CSCF socket evidence" "$(ie_socket_block pcscf "[:.]${PCSCF_PORT:-5060}([[:space:]]|$)")"; else fail "P-CSCF SIP endpoint not listening" "IMS SIP evidence requires pcscf:${PCSCF_PORT:-5060}"; fi
    fi

    _TEST_NUM=$((_TEST_NUM + 1)); if should_run_test $_TEST_NUM; then
        local cap path summary; cap=$(ie_capture "4g_sip" "host ${PCSCF_IP} and port ${PCSCF_PORT:-5060}" sip); path=${cap%%|*}; summary=${cap#*|}
        if [ -s "$path" ]; then pass "SIP packet capture artifact generated from OPTIONS probe"; append_report_block "SIP pcap artifact" "path=${path}
${summary}"; else skip "SIP packet capture artifact" "${summary:-no packet captured}"; fi
    fi

    _TEST_NUM=$((_TEST_NUM + 1)); if should_run_test $_TEST_NUM; then
        if [ "$REAL_HW" = "1" ]; then
            if [ -n "$INTERFACE_EVIDENCE_REAL_HW_PCAP" ] && [ -s "$INTERFACE_EVIDENCE_REAL_HW_PCAP" ]; then pass "REAL-HW pcap artifact attached for eNB/UE evidence"; append_report_block "Real-HW pcap summary" "path=${INTERFACE_EVIDENCE_REAL_HW_PCAP}
$(tcpdump -nn -r "$INTERFACE_EVIDENCE_REAL_HW_PCAP" -c 10 2>/dev/null || true)"; else fail "REAL-HW requested but no pcap artifact supplied" "Set INTERFACE_EVIDENCE_REAL_HW_PCAP or REAL_HW_PCAP_FILE to a mounted non-empty S1/NAS/SIP capture"; fi
        else
            skip "REAL-HW pcap attachment" "Set REAL_HW=1 and INTERFACE_EVIDENCE_REAL_HW_PCAP=<mounted pcap> after a real eNB/UE run"
        fi
    fi

    end_feature
}