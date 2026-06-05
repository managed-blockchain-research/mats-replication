#!/bin/bash
# ============================================================
# MATS Evaluation Harness — Besu @ 4 GB heap
#
# 5 variants × 5 replications = 25 runs, interleaved per rep
#   baseline  : -Dlast.variant=DISABLED         (FIFO)
#   last_wsa  : -Dlast.variant=WORKING_SET_AFFINITY
#   last_hfl  : -Dlast.variant=HYBRID_FEE_LOCALITY  (α=β=0.5)
#   mats      : -Dlast.variant=MATS             (adaptive α/β via EWMA JVM pressure)
#   mats_raw  : -Dlast.variant=MATS_RAW         (ablation — raw signal, no EWMA)
#
# Interleaved order: b1→wsa1→hfl1→mats1→raw1→b2→…
#
# Binary: besu-mats (besu-24.1.1 + MATS-patched blockcreation jar)
# Load:   120s warmup + 300s measure, 150 TPS, 30 workers, 30 contracts
# TX:     stateBloat 200 slots/tx
# GC:     JVM G1GC unified log per run + gc_total_delta_ms from LASTMetricsLogger
# Log:    last.log.path CSV per run (extended schema for MATS/MATS_RAW)
# Output: results/mats_eval_besu/<RUN_ID>/
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

BESU_BIN="/home/yeochan.yoon/besu-mats/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
BENCHCONFIG="benchconfig-last-vs-lass-nm.yaml"
NETWORKCONFIG="networkconfig.json"
DEPLOY_SCRIPT="deploy_multi_contracts.py"

HEAP="4g"
NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"
NO_LASS="-Dlass.old.gen.activation.threshold=2.0"   # LASS never fires at 4g with this workload

REPLICATIONS=5
COOLDOWN_BETWEEN_RUNS=20
INTER_REP_COOLDOWN=60
CALIPER_TIMEOUT=1500

RUN_ID=$(date +%Y%m%d_%H%M%S)_mats_eval_besu
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/mats_eval_besu/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_for_rpc() {
    local max=120 count=0
    echo -n "  Waiting for RPC"
    while [ ${count} -lt ${max} ]; do
        if curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:8545 > /dev/null 2>&1; then
            echo " READY"; return 0
        fi
        echo -n "."; sleep 1; count=$((count+1))
    done
    echo " TIMEOUT"; return 1
}

stop_besu() {
    local pid="$1"
    kill "${pid}" 2>/dev/null || true
    local w=0
    while kill -0 "${pid}" 2>/dev/null && [ ${w} -lt 30 ]; do sleep 1; w=$((w+1)); done
    kill -9 "${pid}" 2>/dev/null || true
    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5
}

# run_single VARIANT REP LAST_VARIANT_FLAG [EXTRA_FLAGS]
run_single() {
    local variant="$1"
    local rep="$2"
    local last_flag="$3"
    local extra_flags="${4:-}"

    local label="${variant}_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"

    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_bmats_${label}_${RUN_ID}"
    local gc_log="${run_dir}/gc_besu.log"
    local last_csv="${run_dir}/last_metrics.csv"

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | mode=${last_flag} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────────────"

    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5

    rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    local java_opts="-Xms${HEAP} -Xmx${HEAP} \
-XX:+UseG1GC \
-XX:MaxGCPauseMillis=200 \
${NEWGEN_FLAGS} \
-Xlog:gc*=info:file=${gc_log}:time,uptime,level,tags:filecount=3,filesize=50M \
-Dlog4j.configurationFile=${LOG4J_CONFIG} \
${last_flag} ${extra_flags} \
-Dlast.log.path=${last_csv} \
${NO_LASS}"

    export BESU_OPTS="${java_opts}"

    nohup "${BESU_BIN}" \
        --network=dev \
        --miner-enabled \
        --miner-coinbase=0xfe3b557e8fb62b89f4916b721be55ceb828dbd73 \
        --data-path="${data_dir}" \
        --rpc-http-enabled --rpc-http-port=8545 --rpc-http-host=0.0.0.0 \
        --rpc-http-cors-origins="*" \
        --rpc-ws-enabled --rpc-ws-port=8546 \
        --rpc-ws-max-active-connections=200 \
        --rpc-http-max-active-connections=200 \
        --host-allowlist="*" \
        --min-gas-price=0 \
        --tx-pool-layer-max-capacity=1000000 \
        --tx-pool-max-prioritized=1000000 \
        --tx-pool-max-future-by-sender=100000 \
        > "${run_dir}/besu_console.log" 2>&1 &
    local besu_pid=$!
    echo "  Besu PID: ${besu_pid}"

    sleep 8
    if ! kill -0 ${besu_pid} 2>/dev/null; then
        echo "  ERROR: Besu died at startup."
        tail -20 "${run_dir}/besu_console.log" || true
        echo "failed=startup" > "${run_dir}/FAILED"; return 1
    fi

    wait_for_rpc || {
        stop_besu "${besu_pid}"
        echo "failed=rpc_timeout" > "${run_dir}/FAILED"; return 1
    }

    echo "  Deploying 30 StateBloater contracts..."
    python3 "${DEPLOY_SCRIPT}" > "${run_dir}/deploy.log" 2>&1
    if ! grep -q "Contract Address:" "${run_dir}/deploy.log" 2>/dev/null; then
        echo "  ERROR: Deploy failed."
        cat "${run_dir}/deploy.log"
        stop_besu "${besu_pid}"
        echo "failed=deploy" > "${run_dir}/FAILED"; return 1
    fi
    sleep 3

    echo "  Running Caliper (120s warmup + 300s measure @ 150 TPS)..."
    local t_start; t_start=$(date +%s)
    timeout ${CALIPER_TIMEOUT} npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${BENCHCONFIG}" \
        --caliper-networkconfig "${NETWORKCONFIG}" \
        > "${run_dir}/caliper_console.log" 2>&1 || true
    local caliper_exit=$?
    local t_end; t_end=$(date +%s)
    local elapsed=$(( t_end - t_start ))
    echo "  Caliper exit: ${caliper_exit}. Elapsed: ${elapsed}s"

    cp caliper.log  "${run_dir}/caliper.log"  2>/dev/null || true
    cp report.html  "${run_dir}/report.html"  2>/dev/null || true

    echo "  Stopping Besu..."
    stop_besu "${besu_pid}"
    rm -rf "${data_dir}"

    # ── Parse GC summary from last_metrics.csv ────────────────────────────────
    if [ -f "${last_csv}" ]; then
        local blocks; blocks=$(( $(wc -l < "${last_csv}") - 1 ))
        # sum gc_total_delta_ms (column 15) and block_duration_ms (column 10)
        local gc_stats
        gc_stats=$(awk -F, 'NR>1 {gc+=$15; dur+=$10; tx+=$4; wh+=$5}
            END {
                printf "total_gc_ms=%.0f\ntrace_duration_ms=%.0f\ntx_total=%d\nwarm_hits=%d\n",
                       gc, dur, tx, wh
            }' "${last_csv}")
        echo "${gc_stats}" > "${run_dir}/gc_summary.txt"
        echo "  LAST log: ${blocks} blocks"
        echo "  $(grep total_gc_ms "${run_dir}/gc_summary.txt" | head -1)"
    fi

    local measure_line; measure_line=$(grep "| measure " "${run_dir}/caliper_console.log" | tail -1 || true)
    echo "  Caliper measure: ${measure_line}"
    echo "  ✓ ${label} complete"
    echo ""
    sleep ${COOLDOWN_BETWEEN_RUNS}
}

# ── Provenance ────────────────────────────────────────────────────────────────
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
MATS Evaluation — Besu 4 GB / 150 TPS / 5 variants × 5 reps
=============================================================
Run ID: ${RUN_ID}
Date:   $(date)
Host:   $(hostname)
Binary: ${BESU_BIN}
Heap:   -Xms4g -Xmx4g (G1GC, MaxGCPauseMillis=200)
Variants: DISABLED, WORKING_SET_AFFINITY, HYBRID_FEE_LOCALITY(0.5/0.5), MATS, MATS_RAW
Load:     150 TPS, 30 contracts × 200 slots, 120s warmup + 300s measure
MATS pressure: raw = 0.5*heap_pct + 0.3*gc_freq_norm + 0.2*gc_time_norm
               ewma = 0.2*raw + 0.8*ewma_prev
               alpha(p) = max(0.05, 0.7-0.5*p), beta = 1-alpha
EOF

# ── Main loop ─────────────────────────────────────────────────────────────────
echo "======================================================================"
echo "MATS Eval Besu | 150 TPS | 120s+300s | 5 variants × 5 reps (interleaved)"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"
echo "Starting 25 runs..."

for rep in $(seq 1 ${REPLICATIONS}); do
    echo ""
    echo "══════════════════════════════════════════════════════════════════"
    echo "REPLICATION ${rep}/${REPLICATIONS}"
    echo "══════════════════════════════════════════════════════════════════"

    run_single "baseline"  ${rep} "-Dlast.variant=DISABLED" || true
    run_single "last_wsa"  ${rep} "-Dlast.variant=WORKING_SET_AFFINITY" || true
    run_single "last_hfl"  ${rep} "-Dlast.variant=HYBRID_FEE_LOCALITY" "-Dlast.alpha=0.5 -Dlast.beta=0.5" || true
    run_single "mats"      ${rep} "-Dlast.variant=MATS" || true
    run_single "mats_raw"  ${rep} "-Dlast.variant=MATS_RAW" || true

    if [ ${rep} -lt ${REPLICATIONS} ]; then
        echo "  (inter-rep cooldown ${INTER_REP_COOLDOWN}s)"
        sleep ${INTER_REP_COOLDOWN}
    fi
done

echo ""
echo "======================================================================"
echo "All 25 runs complete."
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"
