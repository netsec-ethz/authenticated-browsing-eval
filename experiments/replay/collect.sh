#!/bin/bash
# Copy per-iteration outputs from the pos results dir into results/<label>.*
# Usage: collect.sh [lg] [filter]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LG_HOST="${1:-pikachu}"
FILTER_HOST="${2:-bulbasaur}"
USER_NAME="${USER:-$(whoami)}"

ALLOC_DIR=$(ls -dt /srv/testbed/results/${USER_NAME}/default/*/ | head -1)
if [ -z "$ALLOC_DIR" ]; then
    echo "no pos allocation results dir under /srv/testbed/results/${USER_NAME}/default/" >&2
    exit 1
fi
echo "using pos results dir: $ALLOC_DIR"

mkdir -p "$SCRIPT_DIR/results"
rm -f "$SCRIPT_DIR/results"/*.log "$SCRIPT_DIR/results"/*.json "$SCRIPT_DIR/results/replay."*

python3 - "$SCRIPT_DIR" "$ALLOC_DIR" "$LG_HOST" "$FILTER_HOST" <<'PY'
import glob, json, os, shutil, subprocess, sys
script_dir, alloc_dir, lg_host, filter_host = sys.argv[1:]
combos_json = subprocess.check_output(
    ["pos", "allocations", "print_combinations", "--json", lg_host], text=True)
combos = json.loads(combos_json)

def label_for(c):
    return f"pz{c['packet_size']}_rp{c['replay_pct']}"

def find_upload(host, tag, i):
    host_dir = os.path.join(alloc_dir, host)
    for w in range(1, 5):
        p = os.path.join(host_dir, f"{tag}_run{i:0{w}d}.stdout")
        if os.path.exists(p):
            return p
    matches = glob.glob(os.path.join(host_dir, f"{tag}_run*[0-9].stdout"))
    for p in sorted(matches):
        stem = os.path.basename(p)[len(tag)+len("_run"):-len(".stdout")]
        if stem.isdigit() and int(stem) == i:
            return p
    return None

copied = missing = 0
for run_key, combo in combos.items():
    i = int(run_key.removeprefix("run"))
    label = label_for(combo)
    for host, tag, ext in [
        (lg_host,     "pktgen",     "lg.log"),
        (filter_host, "filter",     "filter.log"),
        (filter_host, "filter_tel", "filter_tel.json"),
    ]:
        src = find_upload(host, tag, i)
        dst = os.path.join(script_dir, "results", f"{label}.{ext}")
        if src:
            shutil.copy(src, dst)
            copied += 1
        else:
            missing += 1
            print(f"missing: {host}/{tag}_run{i}.stdout", file=sys.stderr)

    # no per-class counters means the validator was built without PER_CLASS_STATS
    tel = os.path.join(script_dir, "results", f"{label}.filter_tel.json")
    flog = os.path.join(script_dir, "results", f"{label}.filter.log")
    if os.path.exists(tel):
        with open(tel) as f:
            if '"legit_rx"' not in f.read():
                print(f"  WARN telemetry has no class breakdown for {label}, last filter log tail:",
                      file=sys.stderr)
                if os.path.exists(flog):
                    with open(flog) as g:
                        sys.stderr.writelines(g.readlines()[-20:])

print(f"copied {copied} files, missing {missing}")
PY

ls "$SCRIPT_DIR/results/" | head
