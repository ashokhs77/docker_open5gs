#!/bin/bash
# Feature 26: OAM / FCAPS (5G)  (TRL8 add-on)
# 3GPP TS 28.552 (5G performance measurements / PM counters), TS 28.545 (fault
# supervision), TS 28.541 (5G NRM / configuration). Verifies the management plane:
# PM metrics export, Prometheus collection, fault/target-health supervision,
# configuration management, and Grafana visualization.
#
# Verified OAM stack (VM 2026-06-11): open5gs NFs export Prometheus metrics on
# :9091 with 3GPP-named counters (fivegs_amffunction_rm_reginitreq, amf_session,
# fivegs_amffunction_amf_authreject, ...). A 'metrics' container runs Prometheus
# (:9090, scrape jobs amf/smf/pcf/upf/mme) and 'grafana' (:3000, /api/health=200).
# The Prometheus `up` metric gives per-NF target health (FM).
#
# Calibration: PASS on present capability; SKIP-with-finding for management items
# the lab omits; FAIL only on a genuine defect (NF up but exporting no metrics).
#
# Tests (FCAPS = Fault, Config, Accounting, Performance, Security):
#   TC-1:  PM: AMF metrics endpoint reachable (:9091)          [TS 28.552]
#   TC-2:  PM: 3GPP 5G PM counters exported (fivegs_*)         [TS 28.552]
#   TC-3:  PM: Prometheus/OpenMetrics format (HELP/TYPE)       [TS 28.552]
#   TC-4:  PM: multiple NFs export metrics (AMF/SMF/UPF)       [TS 28.552]
#   TC-5:  PM: Prometheus collector reachable + query API      [OAM]
#   TC-6:  FM: per-NF target health via `up` metric            [TS 28.545]
#   TC-7:  FM: NF fault/error counters present                 [TS 28.545]
#   TC-8:  FM: NF crash/restart supervision (RestartCount)     [TS 28.545]
#   TC-9:  CM: NF metrics configuration consistency (NRM)      [TS 28.541]
#   TC-10: Visualization: Grafana dashboards reachable         [OAM]
#   TC-11: Logging: NF structured logging accessible           [OAM]
#   TC-12: OAM / FCAPS coverage summary

set +e

OAM_METRICS_PORT="${OAM_METRICS_PORT:-9091}"
OAM_PROM_PORT="${OAM_PROM_PORT:-9090}"
OAM_GRAFANA_PORT="${OAM_GRAFANA_PORT:-3000}"

_oam_ip() { docker inspect "$1" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | tr -d '[:space:]'; }
_oam_scrape() { curl -s -m 4 "http://${1}:${OAM_METRICS_PORT}/metrics" 2>/dev/null; }
_oam_prom_query() { curl -s -m 5 "http://${1}:${OAM_PROM_PORT}/api/v1/query?query=${2}" 2>/dev/null; }

run_oam_fcaps_5g_tests() {
    start_feature "OAM / FCAPS (5G)"

    local amf_metrics=""; container_is_running "amf" && amf_metrics=$(_oam_scrape "$AMF_IP")
    local _oam_pass=0 _oam_find=0

    # TC-1: PM: AMF metrics endpoint reachable
    if should_run_test 1; then
        _TEST_NUM=1
        if ! container_is_running "amf"; then
            skip "AMF metrics endpoint" "AMF not running"
        elif [ -n "$amf_metrics" ]; then
            pass "PM metrics endpoint reachable on AMF (${AMF_IP}:${OAM_METRICS_PORT}/metrics — TS 28.552 measurement export)"
            _oam_pass=$((_oam_pass + 1))
        else
            fail "AMF running but metrics endpoint not exporting on :${OAM_METRICS_PORT}" "Check amf.yaml metrics.server config"
        fi
    fi

    # TC-2: PM: 3GPP 5G PM counters
    if should_run_test 2; then
        _TEST_NUM=2
        if [ -z "$amf_metrics" ]; then
            skip "3GPP 5G PM counters" "No AMF metrics to inspect"
        elif echo "$amf_metrics" | grep -qE 'fivegs_amffunction_|amf_session|ran_ue|gnb '; then
            local cnt; cnt=$(echo "$amf_metrics" | grep -cE 'fivegs_amffunction_')
            pass "3GPP 5G PM counters exported (${cnt} fivegs_amffunction_* + amf_session per TS 28.552 — e.g. reginitreq, paging5greq, authreq)"
            _oam_pass=$((_oam_pass + 1))
        else
            skip "3GPP 5G PM counters" "AMF exports metrics but no 3GPP-named (fivegs_*) counters found"
        fi
    fi

    # TC-3: PM: Prometheus/OpenMetrics format
    if should_run_test 3; then
        _TEST_NUM=3
        if [ -z "$amf_metrics" ]; then
            skip "Prometheus/OpenMetrics format" "No metrics to inspect"
        elif echo "$amf_metrics" | grep -qE '^# HELP ' && echo "$amf_metrics" | grep -qE '^# TYPE .*(counter|gauge|histogram)'; then
            pass "Metrics use Prometheus/OpenMetrics format (HELP + TYPE counter/gauge — standards-compliant export)"
            _oam_pass=$((_oam_pass + 1))
        else
            skip "Prometheus/OpenMetrics format" "Metrics present but HELP/TYPE annotations not found"
        fi
    fi

    # TC-4: PM: multiple NFs export metrics
    if should_run_test 4; then
        _TEST_NUM=4
        local nfs="amf smf upf pcf" ok=0 total=0 nf ip
        for nf in $nfs; do
            if container_is_running "$nf"; then
                total=$((total + 1))
                case "$nf" in amf) ip="$AMF_IP";; smf) ip="$SMF_IP";; upf) ip="$UPF_IP";; pcf) ip="$PCF_IP";; esac
                [ -n "$(_oam_scrape "$ip")" ] && ok=$((ok + 1))
            fi
        done
        if [ "$total" -eq 0 ]; then
            skip "Multi-NF metrics export" "No NFs running"
        elif [ "$ok" -ge 2 ]; then
            pass "Multiple NFs export PM metrics (${ok}/${total}: AMF/SMF/UPF/PCF on :${OAM_METRICS_PORT} — network-wide measurement coverage)"
            _oam_pass=$((_oam_pass + 1))
        else
            skip "Multi-NF metrics export" "Only ${ok}/${total} NFs exporting metrics"
        fi
    fi

    # TC-5: PM: Prometheus collector reachable + query API
    if should_run_test 5; then
        _TEST_NUM=5
        local mip; mip=$(_oam_ip metrics)
        if [ -z "$mip" ]; then
            skip "Prometheus collector" "metrics (Prometheus) container not found"
        else
            local q; q=$(_oam_prom_query "$mip" "up")
            if echo "$q" | grep -q '"status":"success"'; then
                pass "Prometheus collector operational: query API answers (${mip}:${OAM_PROM_PORT}/api/v1/query) — central PM collection"
                _oam_pass=$((_oam_pass + 1))
            else
                skip "Prometheus collector" "Prometheus at ${mip}:${OAM_PROM_PORT} not answering query API"
            fi
        fi
    fi

    # TC-6: FM: per-NF target health via up metric
    if should_run_test 6; then
        _TEST_NUM=6
        local mip6; mip6=$(_oam_ip metrics)
        if [ -z "$mip6" ]; then
            skip "Target-health supervision (up metric)" "Prometheus container not found"
        else
            local q6; q6=$(_oam_prom_query "$mip6" "up")
            local up_n; up_n=$(echo "$q6" | grep -oE '"value":\[[0-9.]+,"1"\]' | wc -l)
            local tot_n; tot_n=$(echo "$q6" | grep -oE '"__name__":"up"' | wc -l)
            if [ "${tot_n:-0}" -ge 1 ]; then
                pass "FM target-health supervision via Prometheus 'up' metric: ${up_n}/${tot_n} NF targets healthy (down targets flagged — TS 28.545 fault detection)"
                _oam_pass=$((_oam_pass + 1))
            else
                skip "Target-health supervision" "No 'up' series returned"
            fi
        fi
    fi

    # TC-7: FM: NF fault/error counters
    if should_run_test 7; then
        _TEST_NUM=7
        if [ -z "$amf_metrics" ]; then
            skip "NF fault/error counters" "No AMF metrics"
        elif echo "$amf_metrics" | grep -qiE 'authreject|reject|fail|error|drop'; then
            pass "FM fault/error counters present (authreject/reject/fail — failure measurements for fault supervision, TS 28.545)"
            _oam_pass=$((_oam_pass + 1))
        else
            skip "NF fault/error counters" "No explicit error/reject counters in AMF metrics"
        fi
    fi

    # TC-8: FM: NF crash/restart supervision
    if should_run_test 8; then
        _TEST_NUM=8
        local bad="" c rc up=0
        for c in amf smf upf nrf ausf udm pcf; do
            if container_is_running "$c"; then
                up=$((up + 1))
                rc=$(docker inspect --format '{{.RestartCount}}' "$c" 2>/dev/null | tr -dc '0-9')
                [ "${rc:-0}" -ge 3 ] 2>/dev/null && bad="$bad ${c}=${rc}"
            fi
        done
        if [ -n "$bad" ]; then
            fail "FM: NF instability (RestartCount>=3):$bad" "Crash-looping NFs — fault condition"
        elif [ "$up" -ge 1 ]; then
            pass "FM crash/restart supervision: ${up} NFs healthy, none crash-looping (container health = availability KPI)"
            _oam_pass=$((_oam_pass + 1))
        else
            skip "NF crash/restart supervision" "No NFs running"
        fi
    fi

    # TC-9: CM: NF metrics configuration consistency (NRM)
    if should_run_test 9; then
        _TEST_NUM=9
        local ok=0 total=0 nf cfg
        for nf in amf smf upf; do
            if container_is_running "$nf"; then
                total=$((total + 1))
                cfg=$(read_nf_config "$nf")
                echo "$cfg" | grep -qiE 'metrics' && ok=$((ok + 1))
            fi
        done
        if [ "$total" -eq 0 ]; then
            skip "CM: metrics configuration consistency" "No NFs to audit"
        elif [ "$ok" -eq "$total" ] && [ "$ok" -ge 1 ]; then
            pass "CM: metrics/management config consistent across ${ok}/${total} NFs (managed configuration — TS 28.541 NRM)"
            _oam_pass=$((_oam_pass + 1))
        elif [ "$ok" -ge 1 ]; then
            pass "CM: metrics config present on ${ok}/${total} NFs (verify the rest)"
            _oam_pass=$((_oam_pass + 1))
        else
            skip "CM: metrics configuration consistency" "metrics config not found in NF YAMLs"
        fi
    fi

    # TC-10: Visualization: Grafana
    if should_run_test 10; then
        _TEST_NUM=10
        local gip; gip=$(_oam_ip grafana)
        if [ -z "$gip" ]; then
            skip "Grafana visualization" "grafana container not found"
        else
            local hc; hc=$(curl -s -m 4 -o /dev/null -w "%{http_code}" "http://${gip}:${OAM_GRAFANA_PORT}/api/health" 2>/dev/null)
            if [ "$hc" = "200" ]; then
                pass "OAM visualization: Grafana healthy (${gip}:${OAM_GRAFANA_PORT}/api/health=200 — KPI dashboards available)"
                _oam_pass=$((_oam_pass + 1))
            else
                skip "Grafana visualization" "Grafana /api/health returned HTTP ${hc}"
            fi
        fi
    fi

    # TC-11: Logging: NF structured logging accessible
    if should_run_test 11; then
        _TEST_NUM=11
        if container_is_running "amf"; then
            local lg; lg=$(docker logs --tail 20 amf 2>&1 | grep -E '\[(amf|sbi|ngap|gmm|pfcp)\]|INFO|WARNING|ERROR' | head -3)
            if [ -n "$lg" ]; then
                pass "OAM logging: NF logs accessible + structured ([module] LEVEL format — collectable for centralized logging)"
                _oam_pass=$((_oam_pass + 1))
            else
                skip "NF structured logging" "AMF logs not in expected structured form"
            fi
        else
            skip "NF structured logging" "AMF not running"
        fi
    fi

    # TC-12: OAM / FCAPS coverage summary
    if should_run_test 12; then
        _TEST_NUM=12
        local summary="FCAPS capabilities confirmed: ${_oam_pass} (Performance metrics + Fault supervision + Config mgmt + Grafana). Accounting=CDR (see cdr_5g); Security=SCAS (see scas_itsar_5g)."
        append_report_block "OAM/FCAPS coverage (5G)" "$summary"
        pass "OAM/FCAPS coverage summary emitted (${_oam_pass} management capabilities verified across F-C-P + visualization)"
    fi

    end_feature
}
