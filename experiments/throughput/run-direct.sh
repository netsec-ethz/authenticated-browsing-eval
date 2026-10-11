#!/bin/bash
# Throughput sweep over plain ssh (no pos): cores x packet size at line rate.
# Usage: run-direct.sh [lg filter]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LG_HOST="${1:-pikachu}"
FILTER_HOST="${2:-bulbasaur}"

# validator NIC BDFs
FILTER_BDFS=(0000:85:00.0 0000:81:00.1 0000:07:00.0 0000:05:00.0)
LG_MOONGEN_INTFS=(0 1 2 3)

CORES_LIST=(4 8 16 24 32)
PACKET_SIZES=(256 512 1024 1500)

DURATION=60
THREADS=16
FLOWS=1000
RATE_MBPS=160000

mkdir -p "$SCRIPT_DIR/results"
rm -f "$SCRIPT_DIR/results"/*.log "$SCRIPT_DIR/results"/*.json

cleanup_remote() {
    ssh "$LG_HOST"     'pkill -f "[/]root/moongen/build/MoonGen" 2>/dev/null; true' >/dev/null
    ssh "$FILTER_HOST" 'pkill -f "[/]root/AuthBrowsing-dpdk/validator/dpdk_forward" 2>/dev/null; true' >/dev/null
}
trap cleanup_remote EXIT
cleanup_remote

iter=0
total=$(( ${#CORES_LIST[@]} * ${#PACKET_SIZES[@]} ))

for cores in "${CORES_LIST[@]}"; do
for pz in "${PACKET_SIZES[@]}"; do
    iter=$((iter + 1))
    label="c${cores}_pz${pz}"

    echo
    echo "[TP ${iter}/${total}] ${label}  rate=${RATE_MBPS} Mbit/s cores=${cores} pz=${pz}"

    cleanup_remote

    ssh "$FILTER_HOST" "rm -f /tmp/dpdk_forward.log; nohup /root/code/run_ab.sh ${cores} ${FILTER_BDFS[*]} >/tmp/dpdk_forward.log 2>&1 & echo \$!" \
        > /tmp/filter_pid_${iter}.txt

    sleep 12

    ssh "$LG_HOST" "/root/moongen/build/MoonGen \
        /root/AuthBrowsing-dpdk/loadgen/abgen.lua ${LG_MOONGEN_INTFS[*]} \
        -r ${RATE_MBPS} -s ${pz} -t ${THREADS} -f ${FLOWS} &
        PID=\$!
        sleep ${DURATION}
        kill -TERM \$PID 2>/dev/null
        wait \$PID 2>/dev/null
        true" > "$SCRIPT_DIR/results/${label}.lg.log" 2>&1

    ssh "$FILTER_HOST" 'printf "/ethdev/stats,0\n/ethdev/stats,1\n/ethdev/stats,2\n/ethdev/stats,3\n" \
        | python3 /root/dpdk-23.11/usertools/dpdk-telemetry.py' \
        > "$SCRIPT_DIR/results/${label}.filter_tel.json" 2>&1 || true

    # SIGINT, not SIGKILL: SIGKILL leaks hugepages
    ssh "$FILTER_HOST" 'killall -SIGINT dpdk_forward 2>/dev/null; for _ in 1 2 3 4 5; do pgrep -x dpdk_forward >/dev/null || break; sleep 1; done; true' >/dev/null
    ssh "$FILTER_HOST" 'cat /tmp/dpdk_forward.log 2>/dev/null' \
        > "$SCRIPT_DIR/results/${label}.filter.log" 2>/dev/null
done
done

echo
echo "sweep done"
