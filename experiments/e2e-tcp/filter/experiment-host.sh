#!/bin/bash

# Runs on the validator host (pikachu), once per loop iteration.

# exit on error
set -e
# log every command
set -x

source /root/code/pos-variables.sh

DURATION=$(pos_get_variable duration --from-global)
ITERS=$(pos_get_variable iters --from-global)
VAL_LCORES=$(pos_get_variable val_lcores --from-global)
BRIDGE=$(pos_get_variable bridge)

MODE=$(get_parameter mode)

# only RAW_FORWARD differs; the loadgen sets RAW_FWD to match
case "$MODE" in
    raw_no_attack)        VAL_ENV=("RAW_FORWARD=1") ;;
    validate_no_attack)   VAL_ENV=() ;;
    validate_with_attack) VAL_ENV=() ;;
    *) echo "unknown mode: $MODE" >&2; exit 1 ;;
esac

echo "filter mode=$MODE val_env='${VAL_ENV[*]}' bridge=$BRIDGE lcores=$VAL_LCORES"

IFS=',' read -ra IF_ADDRESSES <<< "$(pos_get_variable if-addresses)"

# sync 1: start
pos_sync_robust

# Leftover hugepage state from the previous iteration stops dpdk_forward from starting.
pkill -9 dpdk_forward 2>/dev/null || true
rm -f /dev/hugepages/rtemap_*

cd /root/AuthBrowsing-dpdk/validator
# per-port stats lines dropped to stay under pos's 1 MB upload limit
pos_run --loop filter -- \
    bash -c 'env "$@" 2>&1 | grep --line-buffered -v "^\[stats\] port="' _ \
    "${VAL_ENV[@]}" \
    /root/code/run_ab_e2e.sh "$VAL_LCORES" "$BRIDGE" "${IF_ADDRESSES[@]}"

# let the NICs come up
sleep 20

# sync 2: filter up, lg passed its HTTP smoke test
pos_sync_robust

# sync 3: lg finished all wrk2 reps
pos_sync_robust

# Counters are cumulative since validator start (all ITERS reps).
pos_run --loop --blocking --upload --force-upload filter_tel -- \
    bash -c 'printf "/ab/stats\n/ethdev/stats,0\n/ethdev/stats,1\n/ethdev/stats,2\n/ethdev/stats,3\n/ethdev/stats,4\n/ethdev/xstats,0\n" \
             | python3 /root/dpdk-23.11/usertools/dpdk-telemetry.py'

pos_kill --loop --force-upload filter
killall -SIGINT dpdk_forward 2>/dev/null || true

echo "filter mode=$MODE done (iters=$ITERS, duration=${DURATION}s each)"
