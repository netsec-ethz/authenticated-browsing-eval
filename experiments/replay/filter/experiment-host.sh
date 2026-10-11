#!/bin/bash
# Runs on the filter host (bulbasaur), once per loop iteration: dpdk_forward on the default staged path.

set -e
set -x

source /root/code/pos-variables.sh

DURATION=$(pos_get_variable duration --from-global)

# hugepages leaked by a SIGKILLed previous run
rm -f /dev/hugepages/rtemap_* 2>/dev/null || true

echo "running filter (staged path, 4-way dedup_table) for $DURATION s."

# wait for experiment to start
pos_sync

cd /root/AuthBrowsing-dpdk/validator
CORE_COUNT=$(get_parameter cores)
IFS=',' read -ra IF_ADDRESSES <<< "$(pos_get_variable if-addresses)"

pos_run --loop filter -- /root/code/run_ab.sh "$CORE_COUNT" "${IF_ADDRESSES[@]}"
# Link bring-up after a restart can take 30+ s (i40e autoneg). If lg starts
# early MoonGen sees all ports down and sends nothing, so wait for "RETA programmed".
for _ in $(seq 1 90); do
    grep -q "RETA programmed" /tmp/filter_run*.stdout 2>/dev/null && break
    sleep 1
done
# extra time for autoneg
sleep 10
pos_sync

# wait for lg to stop
pos_sync

# /ab/stats counters are cumulative since startup, so grab them right before the kill
pos_run --loop --blocking --upload --force-upload filter_tel -- \
    bash -c 'printf "/ab/stats\n/ethdev/stats,0\n/ethdev/stats,1\n/ethdev/stats,2\n/ethdev/stats,3\n" \
             | python3 /root/dpdk-23.11/usertools/dpdk-telemetry.py'

pos_kill --loop --force-upload filter
# SIGINT, not SIGKILL: SIGKILL leaks hugepages and breaks the next iteration.
killall -SIGINT dpdk_forward 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -x dpdk_forward >/dev/null || break; sleep 1; done

echo "experiment iteration done"
