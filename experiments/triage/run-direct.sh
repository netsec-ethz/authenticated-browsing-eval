#!/bin/bash
# Triage sweep over plain ssh (no pos): packet size x forged fraction at line rate (4x40G).
# Forged = valid AB packet with a random 8-byte tag instead of the PMAC.
# Usage: run-direct.sh [lg filter]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LG_HOST="${1:-pikachu}"
FILTER_HOST="${2:-bulbasaur}"

# validator NIC BDFs
FILTER_BDFS=(0000:85:00.0 0000:81:00.1 0000:07:00.0 0000:05:00.0)
LG_MOONGEN_INTFS=(0 1 2 3)

PACKET_SIZES=(256 1500)
ATTACK_PCTS=(1 5 20 50 80 99)

DURATION=30
THREADS=16
FLOWS=100
CORES=32
RATE_MBPS=160000

mkdir -p "$SCRIPT_DIR/results"
rm -f "$SCRIPT_DIR/results"/*.log "$SCRIPT_DIR/results"/*.json \
      "$SCRIPT_DIR/results/triage."*

ssh "$FILTER_HOST" 'readelf -p .rodata /root/AuthBrowsing-dpdk/validator/dpdk_forward 2>/dev/null | grep -q "/ab/stats"' \
    || { echo "filter dpdk_forward missing PER_CLASS_STATS, rebuild first" >&2; exit 1; }

cleanup_remote() {
    ssh "$LG_HOST"     'pkill -f "[/]root/moongen/build/MoonGen" 2>/dev/null; true' >/dev/null
    ssh "$FILTER_HOST" 'pkill -f "[/]root/AuthBrowsing-dpdk/validator/dpdk_forward" 2>/dev/null; true' >/dev/null
}
trap cleanup_remote EXIT
cleanup_remote

iter=0
total=$(( ${#PACKET_SIZES[@]} * ${#ATTACK_PCTS[@]} ))

for pz in "${PACKET_SIZES[@]}"; do
for ap in "${ATTACK_PCTS[@]}"; do
    iter=$((iter + 1))
    legit_pct=$((100 - ap))
    label="pz${pz}_fp${ap}"
    mix="legit=${legit_pct},forged=${ap}"

    echo
    echo "[${iter}/${total}] ${label}  rate=${RATE_MBPS} Mbit/s mix=${mix}"

    cleanup_remote

    ssh "$FILTER_HOST" "rm -f /tmp/dpdk_forward.log; nohup /root/code/run_ab.sh ${CORES} ${FILTER_BDFS[*]} >/tmp/dpdk_forward.log 2>&1 & echo \$!" \
        > /tmp/filter_pid_${iter}.txt

    sleep 12

    ssh "$LG_HOST" "/root/moongen/build/MoonGen \
        /root/AuthBrowsing-dpdk/loadgen/abgen.lua ${LG_MOONGEN_INTFS[*]} \
        -r ${RATE_MBPS} -s ${pz} -t ${THREADS} -f ${FLOWS} \
        --mix '${mix}' --malformed-kind random &
        PID=\$!
        sleep ${DURATION}
        kill -TERM \$PID 2>/dev/null
        wait \$PID 2>/dev/null
        true" > "$SCRIPT_DIR/results/${label}.lg.log" 2>&1

    ssh "$FILTER_HOST" 'printf "/ab/stats\n/ethdev/stats,0\n/ethdev/stats,1\n/ethdev/stats,2\n/ethdev/stats,3\n" \
        | python3 /root/dpdk-23.11/usertools/dpdk-telemetry.py' \
        > "$SCRIPT_DIR/results/${label}.filter_tel.json" 2>&1

    # SIGINT, not SIGKILL: SIGKILL leaks hugepages
    ssh "$FILTER_HOST" 'killall -SIGINT dpdk_forward 2>/dev/null; for _ in 1 2 3 4 5; do pgrep -x dpdk_forward >/dev/null || break; sleep 1; done; true' >/dev/null
    ssh "$FILTER_HOST" 'cat /tmp/dpdk_forward.log 2>/dev/null' \
        > "$SCRIPT_DIR/results/${label}.filter.log" 2>/dev/null

    if ! grep -q '"legit_rx"' "$SCRIPT_DIR/results/${label}.filter_tel.json"; then
        echo "  WARN telemetry has no class breakdown for $label, last filter log tail:"
        tail -20 "$SCRIPT_DIR/results/${label}.filter.log" || true
    fi
done
done

echo
echo "sweep done, running analyze-direct.py"
DURATION=$DURATION python3 "$SCRIPT_DIR/analyze-direct.py" "$SCRIPT_DIR/results"
