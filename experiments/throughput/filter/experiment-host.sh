#!/bin/bash
# Runs on the experiment host, once per loop iteration.

set -e
set -x

source /root/code/pos-variables.sh

DURATION=$(pos_get_variable duration --from-global)

# leftover hugepages from a SIGKILLed dpdk_forward
rm -f /dev/hugepages/rtemap_* 2>/dev/null || true

echo "running filter script for $DURATION s."

# wait for experiment to start
pos_sync

# start filter script
cd /root/AuthBrowsing-dpdk/validator
CORE_COUNT=$(get_parameter cores)
IFS=',' read -ra IF_ADDRESSES <<< "$(pos_get_variable if-addresses)"
pos_run --loop filter -- /root/code/run_ab.sh "$CORE_COUNT" "${IF_ADDRESSES[@]}"
# Re-binding + i40e autoneg after the previous iteration can take 30+ s;
# if MoonGen starts before links are up it silently sends nothing.
for _ in $(seq 1 90); do
    grep -q "RETA programmed" /tmp/filter_run*.stdout 2>/dev/null && break
    sleep 1
done
# grace for autoneg
sleep 10
pos_sync

# wait for lg to stop
pos_sync

# per-port NIC drops and per-queue rx, uploaded as filter_tel_run<N>.stdout
pos_run --loop --blocking --upload --force-upload filter_tel -- \
    bash -c 'printf "/ethdev/stats,0\n/ethdev/stats,1\n/ethdev/stats,2\n/ethdev/stats,3\n" \
             | python3 /root/dpdk-23.11/usertools/dpdk-telemetry.py'

pos_kill --loop --force-upload filter
# SIGINT, not SIGKILL: SIGKILL leaks hugepages and breaks the next iteration.
killall -SIGINT dpdk_forward 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -x dpdk_forward >/dev/null || break; sleep 1; done

echo "experiment successful"
