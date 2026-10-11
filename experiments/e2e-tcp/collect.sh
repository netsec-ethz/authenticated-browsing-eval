#!/bin/bash
# Copy wrk2 outputs from the latest pos results dir into <out>/<pkt>/<mode>.iter<rep>.txt for plot-sweep.py.
# Usage: collect.sh [lg_host] [out_dir] [filter_host]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LG_HOST="${1:-bulbasaur}"
OUT_BASE="${2:-$SCRIPT_DIR/results}"
USER_NAME="${USER:-$(whoami)}"

ALLOC_DIR=$(ls -dt /srv/testbed/results/${USER_NAME}/default/*/ | head -1)
if [ -z "$ALLOC_DIR" ]; then
    echo "no pos allocation results dir under /srv/testbed/results/${USER_NAME}/default/" >&2
    exit 1
fi
echo "using pos results dir: $ALLOC_DIR"
LG_DIR="$ALLOC_DIR/$LG_HOST"

shopt -s nullglob
copied=0
for src in "$LG_DIR"/wrk2_*_pkt*_rep*.stdout; do
    base=$(basename "$src" .stdout)
    if [[ "$base" =~ ^wrk2_(.+)_pkt([0-9]+)_rep([0-9]+)$ ]]; then
        mode="${BASH_REMATCH[1]}"
        pkt="${BASH_REMATCH[2]}"
        rep="${BASH_REMATCH[3]}"
        dst_dir="$OUT_BASE/$pkt"
        mkdir -p "$dst_dir"
        cp "$src" "$dst_dir/$mode.iter${rep}.txt"
        copied=$((copied + 1))
    else
        echo "  skip unrecognised: $base" >&2
    fi
done
echo "copied $copied wrk2 result files into $OUT_BASE/{pkt}/<mode>.iter<rep>.txt"

# validator port counters per (mode, pkt), matched via the iteration's loop file
FILTER_DIR="$ALLOC_DIR/${3:-pikachu}"
for tel in "$FILTER_DIR"/filter_tel_run*.stdout; do
    run=$(basename "$tel" .stdout); run=${run#filter_tel_}
    loop=$(ls "$FILTER_DIR"/*_filter_filter_${run}.loop 2>/dev/null | head -1)
    [ -n "$loop" ] || continue
    read -r mode pkt < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["mode"], d["packet_size"])' "$loop")
    mkdir -p "$OUT_BASE/$pkt"
    cp "$tel" "$OUT_BASE/$pkt/filter_tel_$mode.json"
    [ -f "$FILTER_DIR/filter_${run}.stdout" ] && grep '^\[stats\] worker_rx=' "$FILTER_DIR/filter_${run}.stdout" > "$OUT_BASE/$pkt/filter_stats_$mode.log" || true
done
ls "$OUT_BASE"/* 2>/dev/null | head -20
