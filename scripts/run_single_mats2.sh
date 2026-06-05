#!/bin/bash
# One-off: run mats_2 only
set -e
cd /home/yeochan.yoon/caliper-stress-test

RESUME_RUN_ID="20260518_074856_prep_eval_besu"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/prep_eval_besu/${RESUME_RUN_ID}"
BESU_BIN="/home/yeochan.yoon/besu-mats/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
BENCHCONFIG="benchconfig-last-vs-lass-nm.yaml"
NETWORKCONFIG="networkconfig.json"
DEPLOY_SCRIPT="deploy_multi_contracts.py"
HEAP="4g"
NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"
NO_LASS="-Dlass.old.gen.activation.threshold=2.0"
CALIPER_TIMEOUT=1500

VARIANT="mats"
REP=2
LAST_FLAG="-Dlast.variant=MATS"

label="${VARIANT}_${REP}"
run_dir="${RESULTS_DIR}/${label}"
data_dir="/home/yeochan.yoon/caliper-stress-test/data_bprep_${label}_${RESUME_RUN_ID}"
gc_log="${run_dir}/gc_besu.log"
last_csv="${run_dir}/last_metrics.csv"

echo "=============================="
echo "Single run: ${label} | $(date)"
echo "=============================="

pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
sleep 5

mkdir -p "${run_dir}"
rm -rf "${data_dir}"; mkdir -p "${data_dir}"

java_opts="-Xms${HEAP} -Xmx${HEAP} \
-XX:+UseG1GC \
-XX:MaxGCPauseMillis=200 \
${NEWGEN_FLAGS} \
-Xlog:gc*=info:file=${gc_log}:time,uptime,level,tags:filecount=3,filesize=50M \
-Dlog4j.configurationFile=${LOG4J_CONFIG} \
${LAST_FLAG} \
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
BESU_PID=$!
echo "Besu PID: ${BESU_PID}"

sleep 8
if ! kill -0 ${BESU_PID} 2>/dev/null; then
    echo "ERROR: Besu died at startup"
    tail -20 "${run_dir}/besu_console.log"
    exit 1
fi

echo -n "Waiting for RPC"
for i in $(seq 1 120); do
    if curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        http://localhost:8545 > /dev/null 2>&1; then
        echo " READY"; break
    fi
    echo -n "."; sleep 1
done

echo "Deploying contracts..."
python3 "${DEPLOY_SCRIPT}" > "${run_dir}/deploy.log" 2>&1
if ! grep -q "Contract Address:" "${run_dir}/deploy.log" 2>/dev/null; then
    echo "ERROR: Deploy failed"
    cat "${run_dir}/deploy.log"
    kill "${BESU_PID}" 2>/dev/null || true; exit 1
fi
sleep 3

echo "Running Caliper..."
t_start=$(date +%s)
timeout ${CALIPER_TIMEOUT} npx caliper launch manager \
    --caliper-workspace ./ \
    --caliper-benchconfig "${BENCHCONFIG}" \
    --caliper-networkconfig "${NETWORKCONFIG}" \
    > "${run_dir}/caliper_console.log" 2>&1 || true
t_end=$(date +%s)
echo "Caliper done. Elapsed: $(( t_end - t_start ))s"

cp caliper.log "${run_dir}/caliper.log"  2>/dev/null || true
cp report.html "${run_dir}/report.html"  2>/dev/null || true

echo "Stopping Besu..."
kill "${BESU_PID}" 2>/dev/null || true
sleep 5; kill -9 "${BESU_PID}" 2>/dev/null || true
pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
rm -rf "${data_dir}"

if [ -f "${last_csv}" ]; then
    gc_stats=$(awk -F, 'NR>1 {gc+=$15; dur+=$10; tx+=$4; wh+=$5; pa+=$21; pd+=$22}
        END {
            printf "total_gc_ms=%.0f\ntrace_duration_ms=%.0f\ntx_total=%d\nwarm_hits=%d\nprep_admitted=%d\nprep_deferred=%d\n",
                   gc, dur, tx, wh, pa, pd
        }' "${last_csv}")
    echo "${gc_stats}" > "${run_dir}/gc_summary.txt"
    echo "gc_summary.txt written:"
    cat "${run_dir}/gc_summary.txt"
fi

echo ""
echo "Done: ${label} | $(date)"
[ -f "${run_dir}/report.html" ] && echo "report.html: OK" || echo "report.html: MISSING"
[ -f "${run_dir}/gc_summary.txt" ] && echo "gc_summary.txt: OK" || echo "gc_summary.txt: MISSING"
