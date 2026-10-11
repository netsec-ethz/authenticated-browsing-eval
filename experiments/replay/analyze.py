#!/usr/bin/env python3
"""Replay sweep analysis: per-(packet_size, replay_pct) rates from filter telemetry -> replay.csv."""
# dedup_table is 4-way x 2^18 sets, exact on the MAC tag, so it can only miss replays via eviction.
# replay_detection_rate = 1 - replay_tx/replay_rx, legit_fnr = 1 - legit_tx/legit_rx
# (legit_fnr > 0 would mean HW drops, not a real false positive)
import csv
import json
import math
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

ANSI_RE  = re.compile(r'\x1b\[[0-9;]*m')
LABEL_RE = re.compile(r'pz(\d+)_rp(\d+)\.(lg|filter)\.log$')

MG_RE = re.compile(r'\[Device: id=(\d+)\]\s+(TX|RX):\s+([\d.]+)\s+Mpps')

CLASSES = ('unknown', 'legit', 'no_header', 'malformed', 'forged', 'replay')


def parse_lg(path):
    ticks_tx = defaultdict(list)
    ticks_rx = defaultdict(list)
    cur_tx_tick, cur_rx_tick = 0, 0
    tx_seen_devs, rx_seen_devs = set(), set()

    with open(path) as f:
        for raw in f:
            line = ANSI_RE.sub('', raw)
            m = MG_RE.search(line)
            if not m:
                continue
            dev_id = int(m.group(1))
            kind   = m.group(2)
            mpps   = float(m.group(3))
            if kind == 'TX':
                if dev_id in tx_seen_devs:
                    cur_tx_tick += 1
                    tx_seen_devs = set()
                ticks_tx[cur_tx_tick].append(mpps)
                tx_seen_devs.add(dev_id)
            else:
                if dev_id in rx_seen_devs:
                    cur_rx_tick += 1
                    rx_seen_devs = set()
                ticks_rx[cur_rx_tick].append(mpps)
                rx_seen_devs.add(dev_id)

    def steady(ticks):
        totals = [sum(v) for _, v in sorted(ticks.items()) if v]
        if len(totals) < 5:
            return totals[len(totals)//2] if totals else 0.0
        trimmed = totals[2:-2]
        trimmed.sort()
        return trimmed[len(trimmed)//2]

    return steady(ticks_tx) * 1e6, steady(ticks_rx) * 1e6


def parse_filter_telemetry(path, duration_s):
    zero = {
        'rx_pps': 0.0, 'tx_pps': 0.0,
        'class_rx': {c: 0.0 for c in CLASSES},
        'class_tx': {c: 0.0 for c in CLASSES},
        'imissed_pps': 0.0, 'rx_nombuf_pps': 0.0,
        'q_imbalance': 1.0,
    }
    if not os.path.exists(path):
        return zero

    ab = None
    ethdev_ports = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or not line.startswith('{'):
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if '/ab/stats' in obj:
                ab = obj['/ab/stats']
            elif '/ethdev/stats' in obj:
                ethdev_ports.append(obj['/ethdev/stats'])

    if ab is None:
        return zero

    dur = max(duration_s, 1e-9)
    def pps(v): return float(v) / dur

    class_rx = {c: pps(ab.get(f'{c}_rx', 0)) for c in CLASSES}
    class_tx = {c: pps(ab.get(f'{c}_tx', 0)) for c in CLASSES}
    imissed   = sum(p.get('imissed',   0) for p in ethdev_ports)
    rx_nombuf = sum(p.get('rx_nombuf', 0) for p in ethdev_ports)

    q_counts = []
    for p in ethdev_ports:
        q_counts.extend(p.get('q_ipackets', []))
    active_q = [q for q in q_counts if q > 0]
    if active_q:
        q_mean = sum(active_q) / len(active_q)
        q_imbalance = max(active_q) / q_mean if q_mean > 0 else 1.0
    else:
        q_imbalance = 1.0

    return {
        'rx_pps':        sum(class_rx.values()),
        'tx_pps':        sum(class_tx.values()),
        'class_rx':      class_rx,
        'class_tx':      class_tx,
        'imissed_pps':   pps(imissed),
        'rx_nombuf_pps': pps(rx_nombuf),
        'q_imbalance':   q_imbalance,
    }


def _read_duration(results_dir):
    gv = os.path.join(os.path.dirname(os.path.abspath(results_dir)),
                      'global-variables.yml')
    if not os.path.exists(gv):
        gv = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          'global-variables.yml')
    try:
        with open(gv) as f:
            for line in f:
                if line.startswith('duration:'):
                    return float(line.split(':', 1)[1].strip())
    except (OSError, ValueError):
        pass
    return 30.0


def main(results_dir):
    results_dir = Path(results_dir)
    duration_s = _read_duration(results_dir)

    per_key = {}
    for path in sorted(results_dir.iterdir()):
        m = LABEL_RE.search(path.name)
        if not m:
            continue
        pz, rp, kind = m.groups()
        key = (int(pz), int(rp))
        per_key.setdefault(key, {})[kind] = path

    rows = []
    for key in sorted(per_key):
        pz, rp = key
        files = per_key[key]
        lg_tx = lg_rx = 0.0
        tel_path = results_dir / f"pz{pz}_rp{rp}.filter_tel.json"
        filt = parse_filter_telemetry(tel_path, duration_s)
        if 'lg' in files:
            lg_tx, lg_rx = parse_lg(files['lg'])

        legit_rx  = filt['class_rx']['legit']
        legit_tx  = filt['class_tx']['legit']
        replay_rx = filt['class_rx']['replay']
        replay_tx = filt['class_tx']['replay']

        replay_det = (1.0 - replay_tx / replay_rx) if replay_rx > 0 else 0.0
        replay_det = max(0.0, min(1.0, replay_det))

        fnr = (1.0 - legit_tx / legit_rx) if legit_rx > 0 else 0.0
        fnr = max(0.0, min(1.0, fnr))

        rows.append({
            'packet_size':      pz,
            'replay_pct':       rp,
            'lg_tx_pps':        int(lg_tx),
            'lg_rx_pps':        int(lg_rx),
            'rx_pps_total':     int(filt['rx_pps']),
            'tx_pps_total':     int(filt['tx_pps']),
            'legit_rx_pps':     int(legit_rx),
            'legit_tx_pps':     int(legit_tx),
            'replay_rx_pps':    int(replay_rx),
            'replay_tx_pps':    int(replay_tx),
            'replay_detection_rate': f"{replay_det:.6f}",
            'legit_fnr':        f"{fnr:.3e}",
            'imissed_pps':      int(filt['imissed_pps']),
            'rx_nombuf_pps':    int(filt['rx_nombuf_pps']),
            'q_imbalance':      f"{filt['q_imbalance']:.2f}",
        })

    csv_path = results_dir / 'replay.csv'
    with open(csv_path, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else [])
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {csv_path} ({len(rows)} rows)")

    # numbers for the paper; total legit packets is the denominator behind FPR=0
    if rows:
        dets  = [float(r['replay_detection_rate']) for r in rows]
        leaks = [int(r['replay_tx_pps'])           for r in rows]
        fprs  = [float(r['legit_fnr'])             for r in rows]
        total_legit = sum(int(r['legit_rx_pps']) for r in rows) * duration_s
        print("\n=== replay parameters (paper: Replay Traffic) ===")
        print(f"detection rate: [{min(dets):.6f}, {max(dets):.6f}]")
        print(f"residual replay leak (replay_tx): "
              f"{min(leaks)}-{max(leaks)} pps (max {max(leaks)})")
        print(f"FPR (legit_fnr): max {max(fprs):.3e}")
        print(f"total legitimate packets over sweep: {total_legit:.3e} "
              f"(sum legit_rx_pps x {duration_s:.0f}s)")
        print()


if __name__ == '__main__':
    results_dir = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join(os.path.dirname(__file__), 'results')
    main(results_dir)
