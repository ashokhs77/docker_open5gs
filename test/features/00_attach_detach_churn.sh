#!/bin/bash
# Feature 00e: Attach/Detach Churn
# Sustained 4G UE lifecycle coverage for repeated EPC attach, default bearer
# setup, UE-initiated detach, context release, and post-churn recovery.
#
# Tests:
#   TC-1:  UE simulator and EPC churn prerequisites are ready
#   TC-2:  Single attach/detach lifecycle succeeds
#   TC-3:  Same subscriber survives repeated attach/detach cycles
#   TC-4:  Alternating subscribers survive repeated attach/detach cycles
#   TC-5:  Fast back-to-back attach/detach cycles remain stable
#   TC-6:  Mini concurrent attach/detach churn burst remains stable
#   TC-7:  Core containers do not restart during churn
#   TC-8:  Detach/context-release evidence appears or is explicitly recorded
#   TC-9:  Clean attach/detach succeeds after churn

set +e

CHURN_LOG_CURSOR=""
CHURN_RESTARTS_BEFORE=""

_churn_json_get() {
    local json="$1"
    local key="$2"
    printf '%s' "$json" | "$PYTHON_BIN" -c "import sys,json; d=json.load(sys.stdin); v=d.get('$key',''); print('' if v is None else v)" 2>/dev/null || echo ""
}

_churn_ue_sim_import_ok() {
    "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import sys
sys.path.insert(0, '/opt/test')
from ue_sim.ue_simulator import UESimulator
from ue_sim.config import Config
PY
}

_churn_restart_snapshot() {
    local nf value out=""
    for nf in mme sgwc sgwu smf upf pyhss; do
        value=$(docker inspect --format '{{.RestartCount}}' "$nf" 2>/dev/null | tr -dc '0-9')
        out="${out}${nf}=${value:-na} "
    done
    echo "$out" | sed 's/[[:space:]]*$//'
}

_churn_log_evidence() {
    local since_arg=""
    [ -n "$CHURN_LOG_CURSOR" ] && since_arg="--since ${CHURN_LOG_CURSOR}"
    { docker logs $since_arg --tail 800 mme 2>&1; docker logs $since_arg --tail 800 sgwc 2>&1; docker logs $since_arg --tail 800 smf 2>&1; docker logs $since_arg --tail 800 upf 2>&1; } 2>/dev/null |
        grep -Eai 'detach|context.*release|UEContextRelease|Delete Session|delete bearer|PFCP.*(delete|deletion|remove)|GTP.*delete|session.*removed|bearer.*removed' |
        tail -60 || true
}

_churn_run_json() {
    local mode="$1"
    local cycles="$2"
    local subscribers="$3"
    local concurrent="$4"
    local think_ms="$5"
    local port_offset="$6"
    CHURN_MODE="$mode" \
    CHURN_CYCLES="$cycles" \
    CHURN_SUBSCRIBERS="$subscribers" \
    CHURN_CONCURRENT="$concurrent" \
    CHURN_THINK_MS="$think_ms" \
    CHURN_PORT_OFFSET="$port_offset" \
    timeout 240 "$PYTHON_BIN" - 2>/tmp/churn_${mode}_$$.log <<'PY' || echo '{"total":0,"success":0,"failed":1,"error":"python churn runner failed or timed out"}'
import concurrent.futures
import json
import logging
import os
import statistics
import sys
import time

sys.path.insert(0, '/opt/test')
os.environ.setdefault('MME_IP', os.getenv('MME_IP', '172.22.1.9'))
os.environ.setdefault('PCSCF_IP', os.getenv('PCSCF_IP', '172.22.1.21'))
os.environ.setdefault('LOCAL_IP', os.getenv('LOCAL_IP', '172.22.1.200'))
os.environ.setdefault('MCC', os.getenv('MCC', '001'))
os.environ.setdefault('MNC', os.getenv('MNC', '01'))
from ue_sim.ue_simulator import UESimulator
from ue_sim.config import Config

logging.disable(logging.WARNING)
mode = os.environ.get('CHURN_MODE', 'serial')
cycles = int(os.environ.get('CHURN_CYCLES', '1'))
subscribers = max(1, int(os.environ.get('CHURN_SUBSCRIBERS', '1')))
parallel_ues = max(1, int(os.environ.get('CHURN_CONCURRENT', '1')))
think_ms = int(os.environ.get('CHURN_THINK_MS', '0'))
port_offset = int(os.environ.get('CHURN_PORT_OFFSET', '100'))
subs = Config.default_subscribers()


def one_cycle(seq, sub_index, port):
    sub = subs[sub_index % len(subs)]
    out = {
        'seq': seq,
        'imsi': sub.imsi,
        'attach': False,
        'detach': False,
        'attach_ms': 0.0,
        'detach_ms': 0.0,
        'ip': '',
        'error_stage': '',
        'error': '',
    }
    ue = None
    try:
        ue = UESimulator(
            imsi=sub.imsi,
            ki=sub.ki,
            opc=sub.opc,
            msisdn=sub.msisdn,
            imei_sv=sub.imei_sv,
            sip_local_port=Config.SIP_LOCAL_PORT_BASE + port,
        )
        out['attach'] = bool(ue.attach())
        out['attach_ms'] = round(ue.metrics.attach_time_ms, 1)
        out['ip'] = ue.ip_address or ''
        if out['attach']:
            t0 = time.time()
            out['detach'] = bool(ue.detach())
            out['detach_ms'] = round((time.time() - t0) * 1000.0, 1)
        out['error_stage'] = ue.metrics.error_stage
        out['error'] = ue.metrics.error_message
    except Exception as exc:
        out['error'] = str(exc)
        try:
            if ue is not None:
                ue.detach()
        except Exception:
            pass
    return out

results = []
start = time.time()
if mode == 'burst':
    for r in range(cycles):
        with concurrent.futures.ThreadPoolExecutor(max_workers=parallel_ues) as ex:
            futs = []
            for i in range(parallel_ues):
                seq = r * parallel_ues + i
                futs.append(ex.submit(one_cycle, seq, i % subscribers, port_offset + seq))
            for fut in concurrent.futures.as_completed(futs):
                results.append(fut.result())
        if think_ms > 0:
            time.sleep(think_ms / 1000.0)
else:
    for i in range(cycles):
        if mode == 'alternating':
            sub_index = i % subscribers
        else:
            sub_index = 0
        results.append(one_cycle(i, sub_index, port_offset + i))
        if think_ms > 0:
            time.sleep(think_ms / 1000.0)

elapsed_s = round(time.time() - start, 3)
success = sum(1 for r in results if r.get('attach') and r.get('detach'))
attach_ok = sum(1 for r in results if r.get('attach'))
detach_fail = sum(1 for r in results if r.get('attach') and not r.get('detach'))
attach_times = [r.get('attach_ms', 0.0) for r in results if r.get('attach_ms', 0.0) > 0]
failures = [r for r in results if not (r.get('attach') and r.get('detach'))]

def pct(num, den):
    return round((num * 100.0 / den), 1) if den else 0.0

p95 = 0.0
if attach_times:
    if len(attach_times) == 1:
        p95 = attach_times[0]
    else:
        p95 = statistics.quantiles(attach_times, n=20)[18]

print(json.dumps({
    'mode': mode,
    'total': len(results),
    'success': success,
    'attach_ok': attach_ok,
    'detach_fail': detach_fail,
    'success_pct': pct(success, len(results)),
    'elapsed_s': elapsed_s,
    'avg_attach_ms': round(statistics.mean(attach_times), 1) if attach_times else 0.0,
    'p95_attach_ms': round(p95, 1),
    'failures': failures[:5],
    'sample': results[:3],
}))
PY
}

_churn_eval_result() {
    local result="$1"
    local label="$2"
    local min_pct="$3"
    local total success_pct failures
    total=$(_churn_json_get "$result" "total")
    success_pct=$(_churn_json_get "$result" "success_pct")
    failures=$(_churn_json_get "$result" "failures")
    if [ -z "$total" ] || [ "$total" = "0" ]; then
        fail "${label} did not run" "$result"
    elif "$PYTHON_BIN" - "$success_pct" "$min_pct" <<'PY' >/dev/null 2>&1
import sys
sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)
PY
    then
        pass "${label}: ${success_pct}% attach/detach cycles succeeded"
        append_report_block "${label} churn evidence" "$result"
    else
        fail "${label}: only ${success_pct}% attach/detach cycles succeeded" "threshold=${min_pct}%; failures=${failures}; result=${result}"
    fi
}

run_attach_churn_tests() {
    start_feature "Attach Detach Churn"
    CHURN_LOG_CURSOR=$(log_cursor_now 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    CHURN_RESTARTS_BEFORE=$(_churn_restart_snapshot)

    local ue_import_ok=false
    if _churn_ue_sim_import_ok; then
        ue_import_ok=true
    fi

    # TC-1: UE simulator and EPC churn prerequisites are ready
    if should_run_test 1; then
        _TEST_NUM=1
        local missing=""
        for nf in mme sgwc sgwu smf upf pyhss; do
            container_is_running "$nf" || missing="${missing} ${nf}"
        done
        if ! $ue_import_ok; then
            skip "UE simulator import" "Python UE simulator libraries not importable"
        elif [ -n "$missing" ]; then
            fail "EPC churn prerequisites missing" "Containers not running:${missing}"
        elif ! mme_s1ap_ready; then
            fail "MME S1AP not ready for churn" "MME port ${MME_PORT:-36412} not reachable"
        else
            pass "UE simulator import OK and EPC containers ready for churn"
        fi
    fi

    # TC-2: Single attach/detach lifecycle succeeds
    if should_run_test 2; then
        _TEST_NUM=2
        if ! $ue_import_ok; then
            skip "Single attach/detach lifecycle" "Python UE simulator libraries not importable"
        else
            local result
            result=$(_churn_run_json serial 1 1 1 250 120)
            _churn_eval_result "$result" "Single attach/detach lifecycle" 100
        fi
    fi

    # TC-3: Same subscriber survives repeated attach/detach cycles
    if should_run_test 3; then
        _TEST_NUM=3
        if ! $ue_import_ok; then
            skip "Same-subscriber attach/detach churn" "Python UE simulator libraries not importable"
        else
            local result cycles
            cycles="${CHURN_SERIAL_CYCLES:-5}"
            result=$(_churn_run_json serial "$cycles" 1 1 500 130)
            _churn_eval_result "$result" "Same-subscriber repeated churn (${cycles} cycles)" 100
        fi
    fi

    # TC-4: Alternating subscribers survive repeated attach/detach cycles
    if should_run_test 4; then
        _TEST_NUM=4
        if ! $ue_import_ok; then
            skip "Alternating-subscriber attach/detach churn" "Python UE simulator libraries not importable"
        else
            local result cycles subs
            cycles="${CHURN_ALT_CYCLES:-6}"
            subs="${CHURN_ALT_SUBSCRIBERS:-3}"
            result=$(_churn_run_json alternating "$cycles" "$subs" 1 500 150)
            _churn_eval_result "$result" "Alternating-subscriber churn (${cycles} cycles/${subs} subscribers)" 100
        fi
    fi

    # TC-5: Fast back-to-back attach/detach cycles remain stable
    if should_run_test 5; then
        _TEST_NUM=5
        if ! $ue_import_ok; then
            skip "Fast attach/detach churn" "Python UE simulator libraries not importable"
        else
            local result cycles
            cycles="${CHURN_FAST_CYCLES:-5}"
            result=$(_churn_run_json serial "$cycles" 1 1 0 170)
            _churn_eval_result "$result" "Fast back-to-back churn (${cycles} cycles)" 80
        fi
    fi

    # TC-6: Mini concurrent attach/detach churn burst remains stable
    if should_run_test 6; then
        _TEST_NUM=6
        if ! $ue_import_ok; then
            skip "Mini concurrent attach/detach churn" "Python UE simulator libraries not importable"
        else
            local result rounds ues threshold
            rounds="${CHURN_BURST_ROUNDS:-2}"
            ues="${CHURN_BURST_UES:-3}"
            threshold="${CHURN_BURST_MIN_PCT:-80}"
            result=$(_churn_run_json burst "$rounds" "$ues" "$ues" 1000 190)
            _churn_eval_result "$result" "Mini concurrent churn (${rounds} rounds x ${ues} UEs)" "$threshold"
        fi
    fi

    # TC-7: Core containers do not restart during churn
    if should_run_test 7; then
        _TEST_NUM=7
        local restarts_after
        restarts_after=$(_churn_restart_snapshot)
        if [ -z "$CHURN_RESTARTS_BEFORE" ] || [ -z "$restarts_after" ]; then
            skip "Core restart guard during churn" "Could not read Docker restart counts"
        elif [ "$CHURN_RESTARTS_BEFORE" = "$restarts_after" ]; then
            pass "Core restart counts stable during churn"
        else
            fail "Core restart count changed during churn" "before=${CHURN_RESTARTS_BEFORE}; after=${restarts_after}"
        fi
    fi

    # TC-8: Detach/context-release evidence appears or is explicitly recorded
    if should_run_test 8; then
        _TEST_NUM=8
        local evidence
        evidence=$(_churn_log_evidence)
        if [ -n "$evidence" ]; then
            pass "Detach/context-release evidence observed in EPC logs"
            append_report_block "Detach/context-release log evidence" "$evidence"
        else
            skip "Detach/context-release log evidence" "No release/delete log lines emitted at current EPC log level; churn success is covered by TC-2..TC-6"
        fi
    fi

    # TC-9: Clean attach/detach succeeds after churn
    if should_run_test 9; then
        _TEST_NUM=9
        if ! $ue_import_ok; then
            skip "Post-churn clean attach/detach" "Python UE simulator libraries not importable"
        else
            local result
            result=$(_churn_run_json serial 1 1 1 250 230)
            _churn_eval_result "$result" "Post-churn clean attach/detach" 100
        fi
    fi

    end_feature
}