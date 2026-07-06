#!/bin/bash
# Feature 29: Interface Evidence Pack (5G)
# Opt-in TRL8 evidence lane for packet-capture readiness and interface-level
# artifacts. It complements NGAP/PFCP/SBI/IMS tests by proving release runs can
# attach pcaps and socket evidence, without changing normal 5G deployment runs.
#
# TC-1: Docker evidence access
# TC-2: tcpdump toolchain and reports/pcaps directory
# TC-3: NRF/SBI pcap from runner-generated traffic
# TC-4: N2/NGAP SCTP endpoint evidence
# TC-5: N4/N3 PFCP/GTP-U endpoint evidence
# TC-6: IMS SIP endpoint evidence
# TC-7: SIP pcap from runner-generated traffic
# TC-8: REAL_HW external N2/NAS/SIP pcap attachment gate

set +e
REAL_HW="${REAL_HW:-0}"
INTERFACE_EVIDENCE_REAL_HW_PCAP="${INTERFACE_EVIDENCE_REAL_HW_PCAP:-${REAL_HW_PCAP_FILE:-}}"

ie5_pcap_dir() { mkdir -p "${REPORT_DIR}/pcaps" 2>/dev/null || true; echo "${REPORT_DIR}/pcaps"; }
ie5_socket_block() { local container="$1" regex="$2"; docker exec "$container" sh -c "ss -H -ln 2>/dev/null || netstat -ln 2>/dev/null" 2>/dev/null | grep -E "$regex" || true; }

ie5_capture() {
    local label="$1" filter="$2" probe="$3" dir pcap log rc summary
    if ! command -v tcpdump >/dev/null 2>&1; then echo "|tcpdump unavailable"; return 70; fi
    dir=$(ie5_pcap_dir); pcap="${dir}/${label}_$(date +%Y%m%d_%H%M%S).pcap"; log="${pcap}.log"
    timeout 6 tcpdump -i any -s 0 -c 1 -w "$pcap" "$filter" >"$log" 2>&1 &
    local pid=$!
    sleep 1
    case "$probe" in
        nrf) curl -s --max-time 2 "http://${NRF_IP}:${NRF_PORT}/nnrf-nfm/v1/nf-instances" >/dev/null 2>&1 || true ;;
        sip) printf 'OPTIONS sip:interface-evidence@%s SIP/2.0\r\nVia: SIP/2.0/UDP %s:15060;branch=z9hG4bK-iface-evidence-5g\r\nFrom: <sip:probe@%s>;tag=iface5g\r\nTo: <sip:interface-evidence@%s>\r\nCall-ID: iface-evidence-5g-%s@%s\r\nCSeq: 1 OPTIONS\r\nMax-Forwards: 5\r\nContent-Length: 0\r\n\r\n' "$IMS_DOMAIN" "$LOCAL_IP" "$IMS_DOMAIN" "$IMS_DOMAIN" "$$" "$LOCAL_IP" | nc -u -w 1 "$PCSCF_IP" "$PCSCF_PORT" >/dev/null 2>&1 || true ;;
    esac
    wait "$pid" >/dev/null 2>&1; rc=$?
    if [ -s "$pcap" ]; then summary=$(tcpdump -nn -r "$pcap" -c 3 2>/dev/null || true); echo "${pcap}|${summary}"; return 0; fi
    echo "${pcap}|tcpdump rc=${rc}; $(tail -3 "$log" 2>/dev/null | tr '\n' ' ')"; return 1
}

run_interface_evidence_5g_tests() {
    start_feature "Interface Evidence (5G)"

    if should_run_test 1; then _TEST_NUM=1
        if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' >/tmp/interface_evidence_5g_docker_ps.txt 2>/dev/null; then pass "Docker control-plane evidence access available"; append_report_block "Docker evidence sample" "$(head -20 /tmp/interface_evidence_5g_docker_ps.txt)"; else fail "Docker control-plane evidence access unavailable" "Mount /var/run/docker.sock into the test container"; fi
    fi

    if should_run_test 2; then _TEST_NUM=2
        local dir ver; dir=$(ie5_pcap_dir); ver=$(tcpdump --version 2>/dev/null | head -1 || true)
        if [ -n "$ver" ] && [ -d "$dir" ] && [ -w "$dir" ]; then pass "tcpdump toolchain and reports/pcaps artifact directory available"; append_report_block "pcap toolchain" "${ver}; pcap_dir=${dir}"; elif [ -z "$ver" ]; then skip "tcpdump packet-capture toolchain" "Rebuild the 5G test image so test/Dockerfile.5g installs tcpdump"; else fail "reports/pcaps artifact directory not writable" "pcap_dir=${dir}"; fi
    fi

    if should_run_test 3; then _TEST_NUM=3
        local cap path summary; cap=$(ie5_capture "5g_nrf_sbi" "host ${NRF_IP} and port ${NRF_PORT}" nrf); path=${cap%%|*}; summary=${cap#*|}
        if [ -s "$path" ]; then pass "NRF/SBI packet capture artifact generated"; append_report_block "NRF/SBI pcap artifact" "path=${path}
${summary}"; else skip "NRF/SBI packet capture artifact" "${summary:-no packet captured}"; fi
    fi

    if should_run_test 4; then _TEST_NUM=4
        if container_listens_on_port amf 38412; then pass "N2/NGAP SCTP endpoint is listening on AMF:38412"; append_report_block "N2/NGAP socket evidence" "$(ie5_socket_block amf '[:.]38412([[:space:]]|$)')"; else fail "N2/NGAP SCTP endpoint not listening" "AMF must expose N2 38412"; fi
    fi

    if should_run_test 5; then _TEST_NUM=5
        local pfcp="" gtpu=""; container_listens_on_port smf 8805 && pfcp="smf:8805"; container_listens_on_port upf 8805 && pfcp="${pfcp:+$pfcp, }upf:8805"; container_listens_on_port upf 2152 && gtpu="upf:2152"
        if [ -n "$pfcp" ] && [ -n "$gtpu" ]; then pass "N4/N3 endpoint evidence present (${pfcp}; ${gtpu})"; append_report_block "N4/N3 socket evidence" "$(ie5_socket_block smf '[:.]8805([[:space:]]|$)')
$(ie5_socket_block upf '[:.](8805|2152)([[:space:]]|$)')"; else fail "N4/N3 endpoint evidence incomplete" "pfcp=${pfcp:-missing}; gtpu=${gtpu:-missing}"; fi
    fi

    if should_run_test 6; then _TEST_NUM=6
        if container_listens_on_port pcscf "${PCSCF_PORT:-5060}"; then pass "IMS SIP endpoint evidence present on P-CSCF:${PCSCF_PORT:-5060}"; append_report_block "P-CSCF socket evidence" "$(ie5_socket_block pcscf "[:.]${PCSCF_PORT:-5060}([[:space:]]|$)")"; else fail "P-CSCF SIP endpoint not listening" "VoNR/IMS SIP evidence requires pcscf:${PCSCF_PORT:-5060}"; fi
    fi

    if should_run_test 7; then _TEST_NUM=7
        local cap path summary; cap=$(ie5_capture "5g_sip" "host ${PCSCF_IP} and port ${PCSCF_PORT:-5060}" sip); path=${cap%%|*}; summary=${cap#*|}
        if [ -s "$path" ]; then pass "SIP packet capture artifact generated from OPTIONS probe"; append_report_block "SIP pcap artifact" "path=${path}
${summary}"; else skip "SIP packet capture artifact" "${summary:-no packet captured}"; fi
    fi

    if should_run_test 8; then _TEST_NUM=8
        if [ "$REAL_HW" = "1" ]; then
            if [ -n "$INTERFACE_EVIDENCE_REAL_HW_PCAP" ] && [ -s "$INTERFACE_EVIDENCE_REAL_HW_PCAP" ]; then pass "REAL-HW pcap artifact attached for gNB/UE evidence"; append_report_block "Real-HW pcap summary" "path=${INTERFACE_EVIDENCE_REAL_HW_PCAP}
$(tcpdump -nn -r "$INTERFACE_EVIDENCE_REAL_HW_PCAP" -c 10 2>/dev/null || true)"; else fail "REAL-HW requested but no pcap artifact supplied" "Set INTERFACE_EVIDENCE_REAL_HW_PCAP or REAL_HW_PCAP_FILE to a mounted non-empty N2/NAS/SIP capture"; fi
        else
            skip "REAL-HW pcap attachment" "Set REAL_HW=1 and INTERFACE_EVIDENCE_REAL_HW_PCAP=<mounted pcap> after a real gNB/UE run"
        fi
    fi

    end_feature
}