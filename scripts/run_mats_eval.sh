#!/bin/bash
# ============================================================
# MATS Evaluation Harness — Nethermind @ no heap limit
#
# 5 variants × 5 replications = 25 runs, interleaved per rep
#   baseline  : NETHERMIND_LAST_MODE=DISABLED  (FIFO)
#   last_wsa  : NETHERMIND_LAST_MODE=WSA        (warm-set affinity)
#   last_hfl  : NETHERMIND_LAST_MODE=HFL_5_5    (static hybrid, α=β=0.5)
#   mats      : NETHERMIND_LAST_MODE=MATS        (adaptive α/β via EWMA pressure)
#   mats_raw  : NETHERMIND_LAST_MODE=MATS_RAW    (ablation — raw signal, no EWMA)
#
# Interleaved order: b1→wsa1→hfl1→mats1→raw1→b2→wsa2→…
# This controls for temporal state drift across 25 sequential runs.
#
# Binary: nethermind-last (MATS-patched Nethermind.Consensus.Ethash.dll)
# Load:   120s warmup + 300s measure, 150 TPS, 30 workers, 30 contracts
# TX:     stateBloat 200 slots/tx
# GC:     dotnet-trace → NettraceGcParser per run
# Log:    LAST_LOG_FILE CSV per run (extended schema for MATS/MATS_RAW)
# Output: results/mats_eval/<RUN_ID>/
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

NM_DLL="/home/yeochan.yoon/nethermind-last/nethermind.dll"
DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
DT_BIN="${HOME}/.dotnet/tools/dotnet-trace"
GC_PARSER="/home/yeochan.yoon/caliper-stress-test/gc-collector/publish/NettraceGcParser.dll"

NM_CFG="/home/yeochan.yoon/caliper-stress-test/nethermind-caliper-config/caliper_nethdev_cfg.json"
BENCHCONFIG="benchconfig-last-vs-lass-nm.yaml"
NETWORKCONFIG="networkconfig_nethermind_caliper.json"
DEPLOY_SCRIPT="deploy_multi_contracts_nm.js"

REPLICATIONS=5
COOLDOWN_BETWEEN_RUNS=20   # seconds
CALIPER_TIMEOUT=1500        # 120+300+buffer

RUN_ID=$(date +%Y%m%d_%H%M%S)_mats_eval
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/mats_eval/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

export DOTNET_ROOT="/home/yeochan.yoon/.dotnet"
export PATH="${DOTNET_ROOT}:${PATH}:${HOME}/.dotnet/tools"

echo "======================================================================"
echo "MATS Evaluation | 150 TPS | 120s+300s | 5 variants × 5 reps (interleaved)"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_for_rpc() {
    local max_wait=120
    local count=0
    echo -n "  Waiting for RPC"
    while [ ${count} -lt ${max_wait} ]; do
        if curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:8545 > /dev/null 2>&1; then
            echo " READY"
            return 0
        fi
        echo -n "."
        sleep 1
        count=$((count + 1))
    done
    echo " TIMEOUT"
    return 1
}

stop_nm() {
    local nm_pid="$1"
    kill "${nm_pid}" 2>/dev/null || true
    local w=0
    while kill -0 "${nm_pid}" 2>/dev/null && [ "${w}" -lt 30 ]; do
        sleep 1; w=$((w+1))
    done
    kill -9 "${nm_pid}" 2>/dev/null || true
    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5
}

run_single() {
    local variant="$1"   # baseline | last_wsa | last_hfl | mats | mats_raw
    local rep="$2"
    local last_mode="$3" # DISABLED | WSA | HFL_5_5 | MATS | MATS_RAW

    local label="${variant}_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"

    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_n_${label}_${RUN_ID}"

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | mode=${last_mode} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────────────"

    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5

    rm -rf "${data_dir}"
    mkdir -p "${data_dir}"

    export NETHERMIND_LAST_MODE="${last_mode}"
    export LAST_LOG_FILE="${run_dir}/last_metrics.csv"
    unset DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit \
          DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true
    export DOTNET_EnableDiagnostics=1

    nohup "${DOTNET_BIN}" "${NM_DLL}" \
        --config "${NM_CFG}" \
        --Init.BaseDbPath "${data_dir}" \
        --Blocks.MinGasPrice 0 \
        > "${run_dir}/nm_console.log" 2>&1 &
    local nm_pid=$!
    echo "  Nethermind PID: ${nm_pid}"

    sleep 8
    if ! kill -0 "${nm_pid}" 2>/dev/null; then
        echo "  ERROR: Nethermind died at startup"
        tail -20 "${run_dir}/nm_console.log" || true
        echo "failed=startup" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE LAST_LOG_FILE
        return 1
    fi

    wait_for_rpc || {
        stop_nm "${nm_pid}"
        echo "failed=rpc_timeout" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE LAST_LOG_FILE
        return 1
    }

    echo "  Deploying 30 StateBloater contracts..."
    node "${DEPLOY_SCRIPT}" > "${run_dir}/deploy.log" 2>&1
    local contract_addr
    contract_addr=$(grep "Contract Address:" "${run_dir}/deploy.log" | head -1 | awk '{print $3}')
    if [ -z "${contract_addr}" ]; then
        echo "  ERROR: Deploy failed"; cat "${run_dir}/deploy.log"
        stop_nm "${nm_pid}"
        echo "failed=deploy" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE LAST_LOG_FILE
        return 1
    fi
    echo "  First contract: ${contract_addr}"

    sleep 5

    # Start dotnet-trace GC collection
    local nettrace_file="${run_dir}/gc_trace.nettrace"
    local dotnet_trace_pid=""
    if [ -f "${DT_BIN}" ]; then
        "${DT_BIN}" collect \
            --process-id "${nm_pid}" \
            --providers "Microsoft-Windows-DotNETRuntime:0x1:5" \
            --output "${nettrace_file}" \
            > "${run_dir}/dotnet_trace.log" 2>&1 &
        dotnet_trace_pid=$!
        echo "  dotnet-trace PID: ${dotnet_trace_pid}"
    else
        echo "  WARNING: dotnet-trace not found"
    fi

    echo "  Running Caliper (120s warmup + 300s measure @ 150 TPS)..."
    local t_start
    t_start=$(date +%s)

    timeout "${CALIPER_TIMEOUT}" npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${BENCHCONFIG}" \
        --caliper-networkconfig "${NETWORKCONFIG}" \
        > "${run_dir}/caliper_console.log" 2>&1
    local caliper_exit=$?

    local t_end
    t_end=$(date +%s)
    echo "  Caliper exit: ${caliper_exit}. Elapsed: $((t_end - t_start))s"

    # Stop dotnet-trace
    if [ -n "${dotnet_trace_pid}" ] && kill -0 "${dotnet_trace_pid}" 2>/dev/null; then
        kill -INT "${dotnet_trace_pid}" 2>/dev/null || true
        sleep 5
        kill "${dotnet_trace_pid}" 2>/dev/null || true
    fi

    cp caliper.log "${run_dir}/caliper.log" 2>/dev/null || true
    cp report.html "${run_dir}/report.html" 2>/dev/null || true

    echo "  Stopping Nethermind..."
    stop_nm "${nm_pid}"
    rm -rf "${data_dir}"

    unset NETHERMIND_LAST_MODE LAST_LOG_FILE

    # Parse GC trace
    if [ -f "${nettrace_file}" ] && [ -f "${GC_PARSER}" ]; then
        echo "  Parsing GC trace..."
        "${DOTNET_BIN}" "${GC_PARSER}" "${nettrace_file}" 2>/dev/null \
            | tee "${run_dir}/gc_summary.txt" \
            | sed 's/^/    /'
    fi

    # Quick Caliper measure summary
    local measure_line
    measure_line=$(grep "| measure " "${run_dir}/caliper_console.log" 2>/dev/null | tail -1 || true)
    echo "  Caliper measure: ${measure_line}"

    # Quick LAST log summary
    if [ -f "${run_dir}/last_metrics.csv" ]; then
        local block_count
        block_count=$(tail -n +2 "${run_dir}/last_metrics.csv" | wc -l)
        local total_alloc
        total_alloc=$(tail -n +2 "${run_dir}/last_metrics.csv" | awk -F',' '{s+=$9} END {printf "%.1f", s}')
        local total_gc0
        total_gc0=$(tail -n +2 "${run_dir}/last_metrics.csv" | awk -F',' '{s+=$6} END {print s}')
        echo "  LAST log: ${block_count} blocks | alloc_mb_total=${total_alloc} | g0_total=${total_gc0}"
    fi

    echo "  ✓ ${label} complete"
}

# ── Provenance ────────────────────────────────────────────────────────────────
NM_COMMIT=$(cd /home/yeochan.yoon/nethermind && git log --oneline -1 2>/dev/null || echo "unknown")
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
MATS Evaluation — Nethermind, no heap limit
============================================
Run ID: ${RUN_ID}
Date:   $(date)
Host:   $(hostname)

Binary:  ${NM_DLL}
  nethermind.dll: 1.37.0-unstable+68b3cf7d
  Nethermind.Consensus.Ethash.dll: MATS-patched (LastTxPoolTxSource v2 with MatsSignalSampler)
  Nethermind.Consensus.dll: rebuilt to include InternalsVisibleTo("Nethermind.Consensus.Ethash")
  source commit: ${NM_COMMIT}

Load:    150 TPS fixed-rate, 120s warmup + 300s measure, 30 workers
TX:      stateBloat 200 slots/tx, 30 contracts
GC:      CLR default (no heap limit), dotnet-trace per run

Variants (interleaved b1→wsa1→hfl1→mats1→raw1→b2→…):
  baseline  : NETHERMIND_LAST_MODE=DISABLED  (FIFO baseline)
  last_wsa  : NETHERMIND_LAST_MODE=WSA        (warm-set affinity, static locality)
  last_hfl  : NETHERMIND_LAST_MODE=HFL_5_5    (static hybrid fee+locality, α=β=0.5)
  mats      : NETHERMIND_LAST_MODE=MATS        (adaptive α/β via EWMA memory pressure, λ=0.2)
  mats_raw  : NETHERMIND_LAST_MODE=MATS_RAW    (ablation: same but raw signal, no EWMA)

MATS signal: raw = 0.5·heap_pct + 0.3·gc_freq_norm + 0.2·alloc_rate_norm
MATS EWMA:   m_t = 0.2·raw_t + 0.8·m_{t-1}
MATS weights: α(p) = max(0.05, 0.7 - 0.5·p)  β(p) = 1 - α(p)

Key metrics to compare (from last_metrics.csv + gc_summary.txt):
  GC:       total_gc_count, total_pause_ms (nettrace)
  Alloc:    sum(alloc_mb) over all blocks (last_metrics.csv col 9)
  Locality: sum(warm_hits)/sum(tx_count) (last_metrics.csv col 4/3)
  Latency:  P99 from Caliper measure round
  MATS:     mats_alpha/beta time-series (last_metrics.csv cols 12-13)
EOF

# ── Pre-flight ─────────────────────────────────────────────────────────────────
pkill -9 -f "nethermind.dll" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
sleep 3

# ── Main loop: interleaved across reps ────────────────────────────────────────
echo ""
echo "Starting 25 runs (5 variants × 5 reps, interleaved)..."
echo ""

VARIANTS=("baseline:DISABLED" "last_wsa:WSA" "last_hfl:HFL_5_5" "mats:MATS" "mats_raw:MATS_RAW")

for rep in $(seq 1 "${REPLICATIONS}"); do
    echo ""
    echo "══════════════════════════════════════════════════════════════════"
    echo "REPLICATION ${rep}/${REPLICATIONS}"
    echo "══════════════════════════════════════════════════════════════════"

    for entry in "${VARIANTS[@]}"; do
        variant="${entry%%:*}"
        mode="${entry##*:}"

        run_single "${variant}" "${rep}" "${mode}" \
            || echo "  WARNING: ${variant}_${rep} failed, continuing"

        # Cooldown between runs (skip after last run of the rep)
        if [ "${variant}" != "mats_raw" ]; then
            echo "  (cooldown ${COOLDOWN_BETWEEN_RUNS}s)"
            sleep "${COOLDOWN_BETWEEN_RUNS}"
        fi
    done

    # Longer cooldown between replications
    if [ "${rep}" -lt "${REPLICATIONS}" ]; then
        echo "  (inter-rep cooldown 60s)"
        sleep 60
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "======================================================================"
echo "ALL 25 RUNS COMPLETE"
echo "Run ID:  ${RUN_ID}"
echo "Results: ${RESULTS_DIR}"
echo ""
echo "GC summary per run (from gc_summary.txt):"
for variant_rep in baseline_1 last_wsa_1 last_hfl_1 mats_1 mats_raw_1; do
    f="${RESULTS_DIR}/${variant_rep}/gc_summary.txt"
    if [ -f "${f}" ]; then
        gc=$(grep "total_pause_ms=" "${f}" | cut -d= -f2)
        echo "  ${variant_rep}: total_pause_ms=${gc}"
    fi
done
echo ""
echo "Run analysis with:"
echo "  python3 scripts/analyze_mats.py ${RESULTS_DIR}"
echo "======================================================================"
