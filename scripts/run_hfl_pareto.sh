#!/bin/bash
# ============================================================
# HFL Pareto Sweep — fee-locality tradeoff across alpha values
#
# Variants (3 reps each):
#   disabled      : DISABLED              (pure fee baseline)
#   al            : ADDRESS_LOCALITY       (pure locality baseline)
#   hfl_0.1..0.9  : HYBRID_FEE_LOCALITY with graduated alpha
#
# Workload: mixed fee (clustered 1gwei SB / scattered 5gwei SC)
# Heap:     1g, no LASS (isolated HFL effect)
# Load:     100 TPS, 300s measure, 30 workers
# gasLimit: 0x1C9C380 (30M) — creates block-space competition
#
# Abort criteria:
#   - Standard: measure Succ too low, fail rate too high, blocks not advancing
#   - Pareto: after hfl_0.3 group, if curve is still flat → abort immediately
# ============================================================
set -euo pipefail
cd /home/yeochan.yoon/caliper-stress-test

BESU_BIN="/home/yeochan.yoon/besu-24.1.1/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
BENCHCONFIG="benchconfig-hfl-pareto.yaml"
NETWORKCONFIG="networkconfig_hfl_pareto.json"
CONTRACT_MAP="contracts_hfl_pareto.json"
REVENUE_COLLECTOR="scripts/collect_block_revenue.py"

HEAP="1g"
REPLICATIONS=3
NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"

# ── Abort thresholds ──────────────────────────────────────────────────────────
MIN_SUCC=10
MAX_FAIL_PCT=99
MIN_BLOCKS=5
MAX_REJECTIONS=1000
# Pareto curve: after hfl_0.3 group, if HFL avg ratio < AL_avg * PARETO_MIN_LIFT, abort
PARETO_MIN_LIFT="1.15"

RUN_ID=$(date +%Y%m%d_%H%M%S)_hfl_pareto
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/hfl_pareto/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

ABORT_FLAG="${RESULTS_DIR}/ABORT"

# Accumulate group avg ratios for Pareto check
DISABLED_AVG_RATIO=""
AL_AVG_RATIO=""
PREV_HFL_AVG_RATIO=""
PREV_HFL_ALPHA=""

echo "======================================================================"
echo "HFL Pareto Sweep | Heap=${HEAP} | 100 TPS | 300s | ${REPLICATIONS} reps"
echo "gasLimit: 0x1C9C380 (30M) | fee ratio: SB=1gwei SC=2gwei | HFL crossover α≈0.60"
echo "Run ID: ${RUN_ID}"
echo "======================================================================"

if [ ! -f "${NETWORKCONFIG}" ]; then
    echo "ERROR: ${NETWORKCONFIG} not found. Run: python3 deploy_mixed_contracts.py"
    exit 1
fi
if [ ! -f "${CONTRACT_MAP}" ]; then
    echo "ERROR: ${CONTRACT_MAP} not found. Run: python3 deploy_mixed_contracts.py"
    exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_for_rpc() {
    local max_wait=120; local count=0
    echo -n "  Waiting for RPC"
    while [ ${count} -lt ${max_wait} ]; do
        if curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:8545 > /dev/null 2>&1; then
            echo " READY"; return 0
        fi
        echo -n "."; sleep 1; count=$((count+1))
    done
    echo " TIMEOUT"; return 1
}

get_block_number() {
    curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        http://localhost:8545 \
        | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "0"
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

parse_gc_total() {
    local gc_log="$1"
    python3 - "${gc_log}" <<'PYEOF'
import re, sys
gc_re = re.compile(r'Pause.*?(\d+\.\d+)ms')
total = 0.0
with open(sys.argv[1], errors='replace') as f:
    for line in f:
        m = gc_re.search(line)
        if m:
            total += float(m.group(1))
print(f"{total:.1f}")
PYEOF
}

extract_fee_ratio() {
    local run_dir="$1"
    python3 - "${run_dir}/revenue.json" <<'PYEOF'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
    c = d.get("clustered_fee_wei", 0)
    s = d.get("scattered_fee_wei", 0)
    if c > 0:
        print(f"{s/c:.2f}")
    elif s > 0:
        print("INF")   # all SC, zero SB — fee dominates completely
    else:
        print("N/A")   # no txs at all
except:
    print("N/A")
PYEOF
}

extract_group_avg_ratio() {
    local prefix="$1"
    python3 - "${RESULTS_DIR}" "${prefix}" "${REPLICATIONS}" <<'PYEOF'
import sys, json, os
results_dir, prefix, reps = sys.argv[1], sys.argv[2], int(sys.argv[3])
ratios = []
all_inf = True
for rep in range(1, reps+1):
    rev = os.path.join(results_dir, f"{prefix}_{rep}", "revenue.json")
    try:
        d = json.load(open(rev))
        c = d.get("clustered_fee_wei", 0)
        s = d.get("scattered_fee_wei", 0)
        if c > 0:
            ratios.append(s / c)
            all_inf = False
        elif s > 0:
            pass  # INF run, don't append to numeric avg
    except:
        all_inf = False
if ratios:
    avg = sum(ratios)/len(ratios)
    print(f"{avg:.2f}")
elif all_inf:
    print("INF")
else:
    print("N/A")
PYEOF
}

cleanup_tmp() {
    rm -f /tmp/hfl_pareto_sweep.log.* 2>/dev/null || true
    find /tmp -maxdepth 1 -name "besu_hfl_*" -exec rm -rf {} + 2>/dev/null || true
    find /tmp -maxdepth 1 -name "caliper-*" -mmin +30 -exec rm -rf {} + 2>/dev/null || true
    find /tmp -maxdepth 1 -name "*.log" -mmin +60 -user "$(whoami)" -exec rm -f {} + 2>/dev/null || true
    find /tmp -maxdepth 1 -name "*.autocomplete" -exec rm -f {} + 2>/dev/null || true
    # core dumps from RocksDB SIGSEGV on Besu shutdown (1-2GB each)
    find /home/yeochan.yoon/caliper-stress-test -maxdepth 1 -name "core" -o -name "core.*" 2>/dev/null \
        | xargs rm -f 2>/dev/null || true
}

cleanup_run_logs() {
    local run_dir="$1"
    rm -f "${run_dir}/besu_console.log" \
          "${run_dir}/gc_besu.log" \
          "${run_dir}/caliper_console.log" \
          "${run_dir}/caliper.log" \
          "${run_dir}/report.html" \
          "${run_dir}/deploy.log"
    local sz; sz=$(du -sh "${run_dir}" 2>/dev/null | awk '{print $1}')
    echo "  [logs] cleaned run dir → ${sz}"
}

# ── Validate a completed run ──────────────────────────────────────────────────
validate_run() {
    local label="$1"
    local run_dir="${RESULTS_DIR}/${label}"
    local caliper_log="${run_dir}/caliper_console.log"
    local besu_log="${run_dir}/besu_console.log"
    local ok=1

    echo "  [validate] checking ${label}..."

    local bb; bb=$(cat "${run_dir}/block_before.txt" 2>/dev/null || echo 0)
    local ba; ba=$(cat "${run_dir}/block_after.txt"  2>/dev/null || echo 0)
    local bdelta=$(( ba - bb ))
    echo "  [validate] blocks mined: ${bdelta} (min=${MIN_BLOCKS})"
    if [ "${bdelta}" -lt "${MIN_BLOCKS}" ]; then
        echo "  [ABORT] blocks mined=${bdelta} < MIN_BLOCKS=${MIN_BLOCKS}"
        ok=0
    fi

    local measure_succ measure_fail measure_submitted
    measure_succ=$(python3 - "${caliper_log}" <<'PYEOF'
import re, sys
succ = 0
for line in open(sys.argv[1], errors='replace'):
    if 'measure Round' in line and 'Transaction Info' in line:
        m = re.search(r'Succ:\s*(\d+)', line)
        if m: succ = int(m.group(1))
print(succ)
PYEOF
    2>/dev/null || echo 0)

    measure_fail=$(python3 - "${caliper_log}" <<'PYEOF'
import re, sys
fail = 0
for line in open(sys.argv[1], errors='replace'):
    if 'measure Round' in line and 'Transaction Info' in line:
        m = re.search(r'Fail:\s*(\d+)', line)
        if m: fail = int(m.group(1))
print(fail)
PYEOF
    2>/dev/null || echo 0)

    measure_submitted=$(python3 - "${caliper_log}" <<'PYEOF'
import re, sys
sub = 0
for line in open(sys.argv[1], errors='replace'):
    if 'measure Round' in line and 'Transaction Info' in line:
        m = re.search(r'Submitted:\s*(\d+)', line)
        if m: sub = int(m.group(1))
print(sub)
PYEOF
    2>/dev/null || echo 0)

    local fail_pct=0
    if [ "${measure_submitted}" -gt 0 ]; then
        fail_pct=$(( measure_fail * 100 / measure_submitted ))
    fi
    echo "  [validate] measure: submitted=${measure_submitted} succ=${measure_succ} fail=${measure_fail} (${fail_pct}%)"
    echo "  measure_succ=${measure_succ}" >> "${run_dir}/validate.txt"
    echo "  measure_fail=${measure_fail}" >> "${run_dir}/validate.txt"
    echo "  measure_submitted=${measure_submitted}" >> "${run_dir}/validate.txt"

    if [ "${measure_succ}" -lt "${MIN_SUCC}" ]; then
        echo "  [ABORT] measure succ=${measure_succ} < MIN_SUCC=${MIN_SUCC}"
        ok=0
    fi
    if [ "${measure_submitted}" -gt 0 ] && [ "${fail_pct}" -gt "${MAX_FAIL_PCT}" ]; then
        echo "  [ABORT] fail rate=${fail_pct}% > MAX_FAIL_PCT=${MAX_FAIL_PCT}%"
        ok=0
    fi

    local rejections
    rejections=$(grep -c "Rejecting new connection" "${besu_log}" 2>/dev/null; true)
    rejections=${rejections:-0}
    echo "  [validate] besu HTTP rejections: ${rejections} (max=${MAX_REJECTIONS})"
    echo "  besu_rejections=${rejections}" >> "${run_dir}/validate.txt"
    if [ "${rejections}" -gt "${MAX_REJECTIONS}" ]; then
        echo "  [ABORT] besu rejections=${rejections} > MAX_REJECTIONS=${MAX_REJECTIONS}"
        ok=0
    fi

    local evm_reverts
    evm_reverts=$(grep -c "reverted by the EVM" "${caliper_log}" 2>/dev/null; true)
    evm_reverts=${evm_reverts:-0}
    echo "  [validate] EVM reverts: ${evm_reverts}"
    echo "  evm_reverts=${evm_reverts}" >> "${run_dir}/validate.txt"
    if [ "${evm_reverts}" -gt 0 ]; then
        echo "  [ABORT] EVM reverts=${evm_reverts} — gas limit or contract issue"
        ok=0
    fi

    local total_mined
    total_mined=$(python3 - "${besu_log}" <<'PYEOF'
import re, sys
total = sum(int(m.group(1)) for line in open(sys.argv[1], errors='replace')
            for m in [re.search(r'Produced.*?/ (\d+) tx', line)] if m)
print(total)
PYEOF
    2>/dev/null || echo 0)
    echo "  [validate] total txs mined: ${total_mined}"
    echo "  total_mined=${total_mined}" >> "${run_dir}/validate.txt"
    if [ "${total_mined}" -lt 100 ]; then
        echo "  [ABORT] total_mined=${total_mined} < 100 — blocks nearly empty"
        ok=0
    fi

    if [ "${ok}" -eq 0 ]; then
        echo "ABORT: ${label} failed validation at $(date)" > "${ABORT_FLAG}"
        return 1
    fi
    echo "  [validate] OK"
    return 0
}

# ── Pareto curve monotone check (call after each complete HFL alpha group) ────
check_pareto_step() {
    local current_alpha="$1"
    local current_avg="$2"

    echo "  [pareto] α=${current_alpha} avg_ratio=${current_avg}"
    echo "  [pareto] baseline: DISABLED=${DISABLED_AVG_RATIO} AL=${AL_AVG_RATIO}"

    # After hfl_0.7: check if curve has lifted above AL by at least 2x
    # (low-alpha groups α≤0.5 are expected to stay near AL level — that is correct behavior)
    if [ "${current_alpha}" = "0.7" ] && [ "${AL_AVG_RATIO}" != "" ] && [ "${AL_AVG_RATIO}" != "N/A" ] && [ "${AL_AVG_RATIO}" != "INF" ]; then
        local lifted
        lifted=$(python3 -c "
al_str = '${AL_AVG_RATIO}'
cur_str = '${current_avg}'
if cur_str == 'INF':
    print('YES')
    exit()
try:
    al = float(al_str)
    cur = float(cur_str) if cur_str not in ('N/A', '') else 0
    # By α=0.7, fee should dominate enough to lift ratio to at least 2× AL
    print('YES' if cur >= al * 2.0 else 'NO')
except:
    print('N/A')
" 2>/dev/null || echo "N/A")
        if [ "${lifted}" = "NO" ]; then
            echo "  [ABORT] PARETO_FLAT: at α=0.7 ratio=${current_avg}x still not 2× above AL (${AL_AVG_RATIO}x)"
            echo "  [ABORT] Curve is not rising — fee scoring may not be differentiating."
            echo "ABORT: PARETO_FLAT at hfl_0.7 — no fee-locality crossover detected at $(date)" > "${ABORT_FLAG}"
            return 1
        fi
        echo "  [pareto] crossover lift confirmed at α=0.7 ✓"
    fi

    # After any group: warn if not higher than previous HFL group
    if [ "${PREV_HFL_AVG_RATIO}" != "" ] && [ "${PREV_HFL_AVG_RATIO}" != "N/A" ] && [ "${current_avg}" != "N/A" ]; then
        local direction
        direction=$(python3 -c "
prev = float('${PREV_HFL_AVG_RATIO}')
cur = float('${current_avg}')
print('UP' if cur > prev * 0.95 else 'FLAT')
" 2>/dev/null || echo "?")
        echo "  [pareto] α=${PREV_HFL_ALPHA}→${current_alpha}: ${PREV_HFL_AVG_RATIO}x → ${current_avg}x (${direction})"
        if [ "${direction}" = "FLAT" ]; then
            echo "  [WARN] Pareto curve flat between α=${PREV_HFL_ALPHA} and α=${current_alpha}"
        fi
    fi

    PREV_HFL_AVG_RATIO="${current_avg}"
    PREV_HFL_ALPHA="${current_alpha}"
}

# ── Single run ────────────────────────────────────────────────────────────────
run_single() {
    local label="$1"
    local variant="$2"
    local alpha="$3"
    local beta="$4"

    if [ -f "${ABORT_FLAG}" ]; then
        echo "  ABORT flag set — skipping ${label}"
        return 1
    fi

    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"
    local data_dir="/tmp/besu_hfl_${label}_${RUN_ID}"

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%H:%M:%S') | variant=${variant} α=${alpha} β=${beta}"
    echo "────────────────────────────────────────────────────────────────"

    # Clear workspace caliper.log before run to prevent accumulation
    rm -f caliper.log 2>/dev/null || true

    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5
    rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    local last_jvm_opts="-Dlast.variant=${variant}"
    if [ "${variant}" = "HYBRID_FEE_LOCALITY" ]; then
        last_jvm_opts="${last_jvm_opts} -Dlast.alpha=${alpha} -Dlast.beta=${beta}"
    fi
    last_jvm_opts="${last_jvm_opts} -Dlast.log.path=${run_dir}/last_metrics.csv"

    export BESU_OPTS="-Xms${HEAP} -Xmx${HEAP} ${NEWGEN_FLAGS} -XX:+UseG1GC -XX:MaxGCPauseMillis=200 \
-Xlog:gc*=info:file=${run_dir}/gc_besu.log:time,uptime,level,tags:filecount=5,filesize=50M \
${last_jvm_opts} -Dlog4j.configurationFile=${LOG4J_CONFIG}"

    nohup "${BESU_BIN}" \
        --genesis-file=/home/yeochan.yoon/caliper-stress-test/genesis_hfl_pareto.json \
        --data-path="${data_dir}" \
        --rpc-http-enabled --rpc-http-host=0.0.0.0 --rpc-http-port=8545 \
        --rpc-http-cors-origins="*" \
        --rpc-http-api=ETH,NET,WEB3,DEBUG,ADMIN,TXPOOL \
        --rpc-ws-enabled --rpc-ws-host=0.0.0.0 --rpc-ws-port=8546 \
        --rpc-ws-api=ETH,NET,WEB3,DEBUG,ADMIN,TXPOOL \
        --host-allowlist="*" \
        --miner-enabled --miner-coinbase=0xBE0cf996DE312b11990E4BcbBf7Fc156880AcFC8 \
        --min-gas-price=0 \
        --tx-pool-layer-max-capacity=1000000 \
        --tx-pool-max-prioritized=1000000 \
        --tx-pool-max-future-by-sender=100000 \
        --rpc-http-max-active-connections=500 \
        --logging=INFO \
        > "${run_dir}/besu_console.log" 2>&1 &
    local besu_pid=$!
    echo "  Besu PID: ${besu_pid}"

    wait_for_rpc || { stop_besu "${besu_pid}"; echo "failed=rpc_timeout" > "${run_dir}/FAILED"; return 1; }

    echo "  Deploying contracts..."
    python3 deploy_mixed_contracts.py > "${run_dir}/deploy.log" 2>&1 \
        || { stop_besu "${besu_pid}"; echo "failed=deploy" > "${run_dir}/FAILED"; return 1; }
    echo "  Contracts deployed."

    local block_before; block_before=$(get_block_number)
    echo "  Block before caliper: ${block_before}"

    echo "  Running Caliper (300s measure)..."
    local t0; t0=$(date +%s)
    timeout 1500 npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${BENCHCONFIG}" \
        --caliper-networkconfig "${NETWORKCONFIG}" \
        > "${run_dir}/caliper_console.log" 2>&1
    local caliper_exit=$?
    local t1; t1=$(date +%s)
    echo "  Caliper exit=${caliper_exit}  elapsed=$((t1-t0))s"

    local block_after; block_after=$(get_block_number)
    echo "${block_before}" > "${run_dir}/block_before.txt"
    echo "${block_after}"  > "${run_dir}/block_after.txt"
    echo "  Blocks: ${block_before} → ${block_after} (delta=$((block_after - block_before)))"

    if [ $((block_after - block_before)) -gt 0 ]; then
        echo "  Collecting revenue..."
        python3 "${REVENUE_COLLECTOR}" \
            --start "${block_before}" --end "${block_after}" \
            --map "${CONTRACT_MAP}" --out "${run_dir}/revenue.json" \
            --rpc http://localhost:8545 2>/dev/null || echo "  WARNING: revenue collection failed"
    fi

    stop_besu "${besu_pid}"
    rm -rf "${data_dir}"

    local gc_total; gc_total=$(parse_gc_total "${run_dir}/gc_besu.log" 2>/dev/null || echo "N/A")
    echo "${gc_total}" > "${run_dir}/gc_total.txt"

    local fee_ratio; fee_ratio=$(extract_fee_ratio "${run_dir}")
    echo "  GC=${gc_total}ms  SC/SB ratio=${fee_ratio}x"
    echo "  fee_ratio=${fee_ratio}" >> "${run_dir}/validate.txt"

    # Validate (reads besu_console.log + caliper_console.log before they're deleted)
    validate_run "${label}" || true

    # Delete large logs — keep only summary files
    cleanup_run_logs "${run_dir}"
    cleanup_tmp

    echo "  ✓ ${label} done | GC=${gc_total}ms | SC/SB=${fee_ratio}x"
}

# ── Provenance ────────────────────────────────────────────────────────────────
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
HFL Pareto Sweep
================
Run ID:    ${RUN_ID}
Date:      $(date)
Host:      $(hostname)
Binary:    ${BESU_BIN}
Heap:      ${HEAP} (no LASS)
Load:      100 TPS, 300s measure, 30 workers
gasLimit:  0x1C9C380 (30M) — block-space competition
Workload:  stateBloatMixed (SB=30 clustered 1gwei / SC=300 scattered 2gwei)
Reps:      ${REPLICATIONS} per variant
Pareto:    PARETO_MIN_LIFT=${PARETO_MIN_LIFT} (abort if hfl_0.3 shows no lift above AL)

Variants:
  disabled   : DISABLED (pure fee baseline)
  al         : ADDRESS_LOCALITY (pure locality baseline)
  hfl_0.1    : HYBRID_FEE_LOCALITY alpha=0.1 beta=0.9
  hfl_0.3    : alpha=0.3 beta=0.7
  hfl_0.5    : alpha=0.5 beta=0.5
  hfl_0.7    : alpha=0.7 beta=0.3
  hfl_0.9    : alpha=0.9 beta=0.1
EOF

pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
sleep 3

# ── Phase 1: DISABLED baseline ────────────────────────────────────────────────
echo ""; echo "====== PHASE 1: DISABLED (fee baseline) ======"
for rep in $(seq 1 ${REPLICATIONS}); do
    run_single "disabled_${rep}" "DISABLED" "1.0" "0.0" || true
    [ -f "${ABORT_FLAG}" ] && { echo "ABORT after disabled_${rep}"; cat "${ABORT_FLAG}"; exit 1; }
    sleep 10
done
DISABLED_AVG_RATIO=$(extract_group_avg_ratio "disabled")
echo "  [summary] DISABLED avg SC/SB ratio: ${DISABLED_AVG_RATIO}x"

# ── Phase 2: ADDRESS_LOCALITY baseline ───────────────────────────────────────
echo ""; echo "====== PHASE 2: ADDRESS_LOCALITY (locality baseline) ======"
for rep in $(seq 1 ${REPLICATIONS}); do
    run_single "al_${rep}" "ADDRESS_LOCALITY" "0.0" "1.0" || true
    [ -f "${ABORT_FLAG}" ] && { echo "ABORT after al_${rep}"; cat "${ABORT_FLAG}"; exit 1; }
    sleep 10
done
AL_AVG_RATIO=$(extract_group_avg_ratio "al")
echo "  [summary] AL avg SC/SB ratio: ${AL_AVG_RATIO}x"
echo "  [summary] DISABLED/AL spread: ${DISABLED_AVG_RATIO}x → ${AL_AVG_RATIO}x"

# ── Phase 3: HFL sweep ────────────────────────────────────────────────────────
echo ""; echo "====== PHASE 3: HFL Pareto sweep ======"
for alpha_beta in "0.1:0.9" "0.3:0.7" "0.5:0.5" "0.7:0.3" "0.9:0.1"; do
    alpha="${alpha_beta%%:*}"
    beta="${alpha_beta##*:}"

    for rep in $(seq 1 ${REPLICATIONS}); do
        run_single "hfl_${alpha}_${rep}" "HYBRID_FEE_LOCALITY" "${alpha}" "${beta}" || true
        [ -f "${ABORT_FLAG}" ] && { echo "ABORT after hfl_${alpha}_${rep}"; cat "${ABORT_FLAG}"; exit 1; }
        sleep 10
    done

    local_avg=$(extract_group_avg_ratio "hfl_${alpha}")
    echo "  [summary] HFL α=${alpha} avg SC/SB ratio: ${local_avg}x"
    check_pareto_step "${alpha}" "${local_avg}" || true
    [ -f "${ABORT_FLAG}" ] && { echo "ABORT after hfl_${alpha} group"; cat "${ABORT_FLAG}"; exit 1; }
done

# ── Analysis ──────────────────────────────────────────────────────────────────
if [ ! -f "${ABORT_FLAG}" ]; then
    echo ""
    echo "======================================================================"
    echo "ALL RUNS COMPLETE — running analysis"
    echo "======================================================================"
    python3 scripts/analyze_hfl_pareto.py "${RESULTS_DIR}" \
        > "${RESULTS_DIR}/analysis.log" 2>&1 \
        && cat "${RESULTS_DIR}/analysis.log" \
        || echo "WARNING: analysis failed — see ${RESULTS_DIR}/analysis.log"
else
    echo ""; echo "====== SWEEP ABORTED ======"
    cat "${ABORT_FLAG}"
fi

echo "Done. Results: ${RESULTS_DIR}"
