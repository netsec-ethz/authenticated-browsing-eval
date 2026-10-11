#!/bin/bash
# Replay sweep over (packet_size, replay_pct) on already set-up hosts (no reset, no setup).
# Usage: run.sh [switch lg filter]
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if test "$#" -ne 3 -a "$#" -ne 0; then
    echo "Usage: run.sh switch lg filter"
    exit
fi

LG_HOST="${2:-pikachu}"
FILTER_HOST="${3:-bulbasaur}"

cleanup_host() {
    local host="$1"
    echo "cleanup $host"

    pos commands list | awk -v node="$host" '$2 == node && ($4 == "running" || $4 == "pending" || $4 == "error") { print $1 }' | while read -r cmd_id; do
        [ -n "$cmd_id" ] || continue
        pos commands abort "$cmd_id" >/dev/null 2>&1 || true
    done

    pos commands flush "$host" >/dev/null 2>&1 || true

    ssh "$host" 'pkill -f "[/]root/moongen/build/MoonGen" >/dev/null 2>&1 || true; pkill -f "[/]root/AuthBrowsing-dpdk/validator/dpdk_forward" >/dev/null 2>&1 || true;' >/dev/null 2>&1 || true
}

cleanup_host "$LG_HOST"
cleanup_host "$FILTER_HOST"

# analyze.py needs per-class /ab/stats, only built with PER_CLASS_STATS
ssh "$FILTER_HOST" 'readelf -p .rodata /root/AuthBrowsing-dpdk/validator/dpdk_forward 2>/dev/null | grep -q "/ab/stats"' \
    || { echo "filter dpdk_forward missing PER_CLASS_STATS, rebuild first" >&2; exit 1; }

echo "load variables files"
pos allocations set_variables "$LG_HOST" "$SCRIPT_DIR/lg/host-variables.yml"
pos allocations set_variables "$FILTER_HOST" "$SCRIPT_DIR/filter/host-variables.yml"
pos allocations set_variables "$LG_HOST" "$SCRIPT_DIR/global-variables.yml" --as-global
pos allocations set_variables "$FILTER_HOST" "$SCRIPT_DIR/global-variables.yml" --as-global
pos allocations set_variables "$LG_HOST" "$SCRIPT_DIR/loop-variables.yml" --as-loop
pos allocations set_variables "$FILTER_HOST" "$SCRIPT_DIR/loop-variables.yml" --as-loop

pos no bootstrap "$LG_HOST"
pos no bootstrap "$FILTER_HOST"

echo "run experiments (loop over packet_size x replay_pct)..."
{ pos commands launch --loop --infile "$SCRIPT_DIR/lg/experiment-host.sh"     --blocking "$LG_HOST";     echo "-> $LG_HOST experiments done"; } &
{ pos commands launch --loop --infile "$SCRIPT_DIR/filter/experiment-host.sh" --blocking "$FILTER_HOST"; echo "-> $FILTER_HOST experiments done"; } &
wait

echo "experiment completed"

bash "$SCRIPT_DIR/collect.sh" "$LG_HOST" "$FILTER_HOST"
python3 "$SCRIPT_DIR/analyze.py" "$SCRIPT_DIR/results"
