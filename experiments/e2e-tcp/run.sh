#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if test "$#" -ne 4 -a "$#" -ne 0; then
    echo "Usage: run.sh lg filter server"
    echo "  defaults: lg=bulbasaur filter=pikachu server=snorlax"
    exit
fi

LG_HOST="${2:-bulbasaur}"
FILTER_HOST="${3:-pikachu}"
SERVER_HOST="${4:-snorlax}"

cleanup_host() {
    local host="$1"
    echo "cleanup $host"

    pos commands list | awk -v node="$host" '$2 == node && ($4 == "running" || $4 == "pending" || $4 == "error") { print $1 }' | while read -r cmd_id; do
        [ -n "$cmd_id" ] || continue
        pos commands abort "$cmd_id" >/dev/null 2>&1 || true
    done

    pos commands flush "$host" >/dev/null 2>&1 || true

    ssh "$host" 'pkill -f "[/]root/moongen/build/MoonGen" >/dev/null 2>&1 || true; pkill -f "[/]root/AuthBrowsing-dpdk/validator/dpdk_forward" >/dev/null 2>&1 || true; pkill -f "[/]tmp/wrk2/wrk" >/dev/null 2>&1 || true;' >/dev/null 2>&1 || true
}

cleanup_host "$LG_HOST"
cleanup_host "$FILTER_HOST"
cleanup_host "$SERVER_HOST"

echo "load variables files"
pos allocations set_variables "$LG_HOST"     "$SCRIPT_DIR/lg/host-variables.yml"
pos allocations set_variables "$FILTER_HOST" "$SCRIPT_DIR/filter/host-variables.yml"
pos allocations set_variables "$SERVER_HOST" "$SCRIPT_DIR/server/host-variables.yml"
pos allocations set_variables "$LG_HOST"     "$SCRIPT_DIR/global-variables.yml" --as-global
pos allocations set_variables "$FILTER_HOST" "$SCRIPT_DIR/global-variables.yml" --as-global
pos allocations set_variables "$SERVER_HOST" "$SCRIPT_DIR/global-variables.yml" --as-global
pos allocations set_variables "$LG_HOST"     "$SCRIPT_DIR/loop-variables.yml" --as-loop
pos allocations set_variables "$FILTER_HOST" "$SCRIPT_DIR/loop-variables.yml" --as-loop
pos allocations set_variables "$SERVER_HOST" "$SCRIPT_DIR/loop-variables.yml" --as-loop

pos no bootstrap "$LG_HOST"
pos no bootstrap "$FILTER_HOST"
pos no bootstrap "$SERVER_HOST"

# Poll instead of --blocking: the await long-poll goes through Apache and 502s
# after ~3 min, while one iter here (50 x 30 s wrk2) takes ~25 min.
launch_loop_robust() {
    local script="$1" host="$2" name="$3"
    pos commands launch --loop --infile "$script" --name "$name" -n "$host" >/dev/null \
        || { echo "FAIL: submit $name on $host returned non-zero" >&2; return 1; }
    while true; do
        local active
        active=$(pos commands list "$host" 2>/dev/null \
            | awk -v name="$name" 'NR>2 && $1 ~ name && ($4 == "running" || $4 == "pending")' \
            | wc -l)
        [[ "$active" -eq 0 ]] && break
        sleep 30
    done
    local errored
    errored=$(pos commands list "$host" 2>/dev/null \
        | awk -v name="$name" 'NR>2 && $1 ~ name && $4 == "error"' | wc -l)
    if [[ "$errored" -gt 0 ]]; then
        echo "FAIL: $errored loop iters of $name on $host ended in error" >&2
        return 1
    fi
    return 0
}

echo "run experiments (loop over mode)..."
launch_loop_robust "$SCRIPT_DIR/lg/experiment-host.sh"     "$LG_HOST"     lg_pktgen     && echo "-> $LG_HOST experiments done"     || { echo "ABORT: $LG_HOST run failed" >&2; exit 1; } &
PID_LG=$!
launch_loop_robust "$SCRIPT_DIR/filter/experiment-host.sh" "$FILTER_HOST" filter_filter && echo "-> $FILTER_HOST experiments done" || { echo "ABORT: $FILTER_HOST run failed" >&2; exit 1; } &
PID_FILTER=$!
launch_loop_robust "$SCRIPT_DIR/server/experiment-host.sh" "$SERVER_HOST" server_serve  && echo "-> $SERVER_HOST experiments done" || { echo "ABORT: $SERVER_HOST run failed" >&2; exit 1; } &
PID_SERVER=$!
wait "$PID_LG"     || { echo "ABORT: $LG_HOST run failed" >&2; exit 1; }
wait "$PID_FILTER" || { echo "ABORT: $FILTER_HOST run failed" >&2; exit 1; }
wait "$PID_SERVER" || { echo "ABORT: $SERVER_HOST run failed" >&2; exit 1; }

echo "experiment completed"
