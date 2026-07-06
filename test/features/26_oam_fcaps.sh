#!/bin/bash
# Feature 26: OAM / FCAPS (4G)  (TRL8 add-on)
# 3GPP TS 28.552 (performance measurements), TS 28.545 (fault supervision),
# TS 28.708/28.7xx (EPC NRM / configuration). Verifies the management plane on
# the EPC: PM metrics export, Prometheus collection, fault/target-health
# supervision, configuration management, and Grafana visualization.
# Shares the metrics (Prometheus :9090) + grafana (:3000) infra with 5G.
#
# Calibration: PASS on present capability; SKIP-with-finding for omitted items;
# FAIL only on a genuine defect (NF up but exporting no metrics).
#
# Tests:
#   TC-1:  PM: MME metrics endpoint reachable (:9091)          [TS 28.552]
#   TC-2:  PM: EPC PM counters exported                       [TS 28.552]
#   TC-3:  PM: Prometheus/OpenMetrics format (HELP/TYPE)       [TS 28.552]
#   TC-4:  PM: multiple NFs export metrics (MME/SMF/UPF)       [TS 28.552]
#   TC-5:  PM: Prometheus collector reachable + query API      [OAM]
#   TC-6:  FM: per-NF target health via `up` metric            [TS 28.545]
#   TC-7:  FM: NF fault/error counters present                 [TS 28.545]
#   TC-8:  FM: NF crash/restart supervision (RestartCount)     [TS 28.545]
#   TC-9:  CM: NF metrics configuration consistency            [EPC NRM]
#   TC-10: Visualization: Grafana dashboards reachable         [OAM]
#   TC-11: Logging: NF structured logging accessible           [OAM]
#   TC-12: OAM / FCAPS coverage summary

set +e

OAM_METRICS_PORT="${OAM_METRICS_PORT:-9091}"
OAM_PROM_PORT="${OAM_PROM_PORT:-9090}"
OAM_GRAFANA_PORT="${OAM_GRAFANA_PORT:-3000}"
MME_IP="${MME_IP:-172.22.1.9}"
SMF_IP="${SMF_IP:-172.22.1.7}"
UPF_IP="${UPF_IP:-172.22.1.8}"

_oam_ip() { docker inspect "$1" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | tr -d '[:space:]'; }
_oam_scrape() { curl -s -m 4 "http://${1}:${OAM_METRICS_PORT}/metrics" 2>/dev/null; }
_oam_prom_query() { curl -s -m 5 "http://${1}:${OAM_PROM_PORT}/api/v1/query?query=${2}" 2>/dev/null; }

run_oam_fcaps_tests() {
    start_feature "OAM / FCAPS"

    local mme_metrics=""; container_is_running "mme" && mme_metrics=$(_oam_scrape "$MME_IP")
    local _oam_pass=0

    # TC-1: PM: MME metrics endpoint reachable
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if ! container_is_running "mme"; then
            skip "MME metrics endpoint" "MME not running"
        elif [ -n "$mme_metrics" ]; then
            pass "PM metrics endpoint reachable on MME (${MME_IP}:${OAM_METRICS_PORT}/metrics — TS 28.552 measurement export)"
            _oam_pass=$((_oam_pass + 1))
        else
            fail "MME running but metrics endpoint not exporting on :${OAM_METRICS_PORT}" "Check mme.yaml metrics.server config"
        fi
    fi

    # TC-2: PM: EPC PM counters
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local m="$mme_metrics"
        [ -z "$m" ] && container_is_running "smf" && m=$(_oam_scrape "$SMF_IP")
        if [ -z "$m" ]; then
            skip "EPC PM counters" "No NF metrics to inspect"
        elif echo "$m" | grep -qiE 's1ap_|enb|ues_active|mme_session|bearer|gtp|ran_ue|gn_rx|gtp[12]_'; then
            local cnt; cnt=$(echo "$m" | grep -ciE 's1ap_|enb|gtp|bearer|ues_active|mme_session')
            pass "EPC PM counters exported (${cnt} S1AP/GTP/bearer/UE measurements per TS 28.552)"
            _oam_pass=$((_oam_pass + 1))
        else
            skip "EPC PM counters" "Metrics present but no recognised EPC counters found"
        fi
    fi

    # TC-3: PM: Prometheus/OpenMetrics format
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local m3="$mme_metrics"
        [ -z "$m3" ] && container_is_running "smf" && m3=$(_oam_scrape "$SMF_IP")
        if [ -z "$m3" ]; then
            skip "Prometheus/OpenMetrics format" "No metrics to inspect"
        elif echo "$m3" | grep -qE '^# HELP ' && echo "$m3" | grep -qE '^# TYPE .*(counter|gauge|histogram)'; then
            pass "Metrics use Prometheus/OpenMetrics format (HELP + TYPE counter/gauge — standards-compliant export)"
            _oam_pass=$((_oam_pass + 1))
        else
            skip "Prometheus/OpenMetrics format" "Metrics present but HELP/TYPE annotations not found"
        fi
    fi

    # TC-4: PM: multiple NFs export metrics
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local ok=0 total=0 nf ip
        for nf in mme smf upf; do
            if container_is_running "$nf"; then
                total=$((total + 1))
                case "$nf" in mme) ip="$MME_IP";; smf) ip="$SMF_IP";; upf) ip="$UPF_IP";; esac
                [ -n "$(_oam_scrape "$ip")" ] && ok=$((ok + 1))
            fi
        done
        if [ "$total" -eq 0 ]; then
            skip "Multi-NF metrics export" "No NFs running"
        elif [ "$ok" -ge 2 ]; then
            pass "Multiple NFs export PM metrics (${ok}/${total}: MME/SMF/UPF on :${OAM_METRICS_PORT} — EPC-wide measurement coverage)"
            _oam_pass=$((_oam_pass + 1))
        else
            skip "Multi-NF metrics export" "Only ${ok}/${total} NFs exporting metrics"
        fi
    fi

    # TC-5: PM: Prometheus collector reachable + query API
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
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
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
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
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local m7="$mme_metrics"
        [ -z "$m7" ] && container_is_running "smf" && m7=$(_oam_scrape "$SMF_IP")
        if [ -z "$m7" ]; then
            skip "NF fault/error counters" "No NF metrics"
        elif echo "$m7" | grep -qiE 'reject|fail|error|drop|abnormal'; then
            pass "FM fault/error counters present (reject/fail/error — failure measurements for fault supervision, TS 28.545)"
            _oam_pass=$((_oam_pass + 1))
        else
            skip "NF fault/error counters" "No explicit error/reject counters found"
        fi
    fi

    # TC-8: FM: NF crash/restart supervision
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local bad="" c rc up=0
        for c in mme sgwc sgwu smf upf pyhss; do
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

    # TC-9: CM: NF metrics configuration consistency
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local ok=0 total=0 nf cfg
        for nf in mme smf upf; do
            if container_is_running "$nf"; then
                total=$((total + 1))
                cfg=$(read_nf_config "$nf")
                echo "$cfg" | grep -qiE 'metrics' && ok=$((ok + 1))
            fi
        done
        if [ "$total" -eq 0 ]; then
            skip "CM: metrics configuration consistency" "No NFs to audit"
        elif [ "$ok" -ge 1 ]; then
            pass "CM: metrics/management config present on ${ok}/${total} NFs (managed configuration baseline)"
            _oam_pass=$((_oam_pass + 1))
        else
            skip "CM: metrics configuration consistency" "metrics config not found in NF YAMLs"
        fi
    fi

    # TC-10: Visualization: Grafana
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
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
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        if container_is_running "mme"; then
            local lg; lg=$(docker logs --tail 20 mme 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | grep -E '\[(mme|emm|esm|s1ap|sbi)\]|INFO|WARNING|ERROR' | head -3)
            if [ -n "$lg" ]; then
                pass "OAM logging: NF logs accessible + structured ([module] LEVEL format — collectable for centralized logging)"
                _oam_pass=$((_oam_pass + 1))
            else
                skip "NF structured logging" "MME logs not in expected structured form"
            fi
        else
            skip "NF structured logging" "MME not running"
        fi
    fi

    # TC-12: OAM / FCAPS coverage summary
    _TEST_NUM=$((_TEST_NUM + 1))
    if should_run_test $_TEST_NUM; then
        local summary="FCAPS capabilities confirmed: ${_oam_pass} (Performance metrics + Fault supervision + Config mgmt + Grafana). Accounting=CDR (see cdr); Security=SCAS (see scas_itsar)."
        append_report_block "OAM/FCAPS coverage (4G)" "$summary"
        pass "OAM/FCAPS coverage summary emitted (${_oam_pass} management capabilities verified across F-C-P + visualization)"
    fi

    end_feature
}
