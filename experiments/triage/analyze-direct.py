#!/usr/bin/env python3
"""Forged-only triage: steady-state rates from the loadgen log, /ab/stats as a cross-check."""
import csv
import math
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

ANSI_RE  = re.compile(r'\x1b\[[0-9;]*m')
LABEL_RE = re.compile(r'pz(\d+)_fp(\d+)\.(lg|filter)\.log$')
MG_RE    = re.compile(r'\[Device: id=(\d+)\]\s+(TX|RX):\s+([\d.]+)\s+Mpps')

CLASSES = ('unknown', 'legit', 'no_header', 'malformed', 'forged', 'replay')


def parse_lg_steady(path):
    """Median (tx_pps, rx_pps) summed over devices, first/last 2 ticks dropped."""
    ticks_tx = defaultdict(list)
    ticks_rx = defaultdict(list)
    cur_tx_tick = cur_rx_tick = 0
    tx_seen = set()
    rx_seen = set()
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
                if dev_id in tx_seen:
                    cur_tx_tick += 1
                    tx_seen = set()
                ticks_tx[cur_tx_tick].append(mpps)
                tx_seen.add(dev_id)
            else:
                if dev_id in rx_seen:
                    cur_rx_tick += 1
                    rx_seen = set()
                ticks_rx[cur_rx_tick].append(mpps)
                rx_seen.add(dev_id)

    def steady(ticks):
        totals = [sum(v) for _, v in sorted(ticks.items()) if v]
        if len(totals) < 5:
            return totals[len(totals) // 2] if totals else 0.0
        trimmed = totals[2:-2]
        trimmed.sort()
        return trimmed[len(trimmed) // 2]

    return steady(ticks_tx) * 1e6, steady(ticks_rx) * 1e6


def parse_filter_telemetry(path):
    """Return (ab_stats, [per-port ethdev stats]), both cumulative."""
    if not os.path.exists(path):
        return None, []
    ab = None
    ethdev_ports = []
    for line in open(path):
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
    return ab, ethdev_ports


def main(results_dir):
    results_dir = Path(results_dir)

    rows = []
    for path in sorted(results_dir.iterdir()):
        m = LABEL_RE.search(path.name)
        if not m or m.group(3) != 'lg':
            continue
        pz, fp, _ = m.groups()
        pz = int(pz); fp = int(fp)
        legit_pct = (100 - fp) / 100.0
        forged_pct = fp / 100.0

        lg_tx, lg_rx = parse_lg_steady(path)

        # cumulative validator counters, only used as a cross-check
        ab, ports = parse_filter_telemetry(results_dir /
                                           f'pz{pz}_fp{fp}.filter_tel.json')
        ab = ab or {}
        legit_rx_cum  = ab.get('legit_rx', 0)
        legit_tx_cum  = ab.get('legit_tx', 0)
        forged_rx_cum = ab.get('forged_rx', 0)
        forged_tx_cum = ab.get('forged_tx', 0)

        # NIC drops happen before classification, so split imissed by the offered mix.
        # Counters also include a few idle seconds, /30 is close enough.
        imissed_cum = sum(p.get('imissed', 0) for p in ports)
        nombuf_cum  = sum(p.get('rx_nombuf', 0) for p in ports)
        imissed_pps = imissed_cum / 30.0
        legit_dropped_nic_pps  = imissed_pps * legit_pct
        forged_dropped_nic_pps = imissed_pps * forged_pct

        offered_legit  = lg_tx * legit_pct
        offered_forged = lg_tx * forged_pct

        # every forged packet fails MAC verify, so all RX is legit
        forwarded_legit  = lg_rx
        forwarded_forged = 0.0

        legit_fpr_cum  = (1.0 - legit_tx_cum / legit_rx_cum) if legit_rx_cum else 0.0
        forged_drop_cum = (1.0 - forged_tx_cum / forged_rx_cum) if forged_rx_cum else 0.0

        rows.append({
            'packet_size':           pz,
            'forged_pct':            fp,
            'lg_tx_pps':             int(lg_tx),
            'lg_rx_pps':             int(lg_rx),
            'offered_legit_pps':     int(offered_legit),
            'offered_forged_pps':    int(offered_forged),
            'forwarded_legit_pps':   int(forwarded_legit),
            'forwarded_forged_pps':  int(forwarded_forged),
            'imissed_pps':           int(imissed_pps),
            'legit_dropped_nic_pps':  int(legit_dropped_nic_pps),
            'forged_dropped_nic_pps': int(forged_dropped_nic_pps),
            'rx_nombuf_pps':         int(nombuf_cum / 30.0),
            'legit_fpr_cum':         f'{legit_fpr_cum:.3e}',
            'forged_drop_rate_cum':  f'{forged_drop_cum:.6f}',
        })

    rows.sort(key=lambda r: (r['packet_size'], r['forged_pct']))
    csv_path = results_dir / 'triage.csv'
    with open(csv_path, 'w', newline='') as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()) if rows else [])
        w.writeheader()
        w.writerows(rows)
    print(f'wrote {csv_path} ({len(rows)} rows)')

    # numbers for the paper; forged forwarded must be 0
    if rows:
        drops      = [float(r['forged_drop_rate_cum']) for r in rows]
        fwd_forged = [int(r['forwarded_forged_pps'])   for r in rows]
        fprs       = [float(r['legit_fpr_cum'])        for r in rows]
        print('\n=== triage parameters (Forged Traffic) ===')
        print(f'forged drop rate: [{min(drops):.6f}, {max(drops):.6f}]')
        print(f'forged forwarded (passed verification): '
              f'max {max(fwd_forged)} pps over sweep')
        print(f'legit FPR (legit_fpr_cum): max {max(fprs):.3e}')
        print()

    if not rows:
        return

    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        print('matplotlib not installed; skipping figure')
        return

    plt.rcParams.update({'font.family': 'DejaVu Serif'})

    # 1500 B looks the same as 256 B (no NIC drops), so only in the CSV
    PLOT_SIZES = (92, 256)
    rows = [r for r in rows if r['packet_size'] in PLOT_SIZES]
    packet_sizes = sorted({r['packet_size'] for r in rows})
    colors = {92: '#2ca02c', 256: '#1f77b4'}

    for ext in ('png', 'pdf'):
        fig, ax = plt.subplots(figsize=(2.8, 2.4))
        ax.set_xlim(-3, 102)

        # line style = role, colour = packet size
        offered_lines = []
        for pz in packet_sizes:
            sub = sorted([r for r in rows if r['packet_size'] == pz],
                         key=lambda r: r['forged_pct'])
            xs        = [r['forged_pct']    for r in sub]
            offered   = [r['lg_tx_pps']  / 1e6 for r in sub]
            forwarded = [r['lg_rx_pps']  / 1e6 for r in sub]
            led       = [r['legit_dropped_nic_pps'] / 1e6 for r in sub]
            c = colors.get(pz, 'tab:gray')
            ax.fill_between(xs, forwarded, offered, color=c, alpha=0.10, linewidth=0)
            line, = ax.plot(xs, offered, marker='o', linestyle='-',
                            linewidth=1.6, markersize=4, color=c,
                            label=f'{pz} B')
            offered_lines.append(line)
            ax.plot(xs, forwarded, marker='s', linestyle='--',
                    linewidth=1.6, markersize=3.5, color=c)
            ax.plot(xs, led, marker='+', linestyle=':',
                    linewidth=1.2, markersize=7, markeredgewidth=1.6,
                    color=c, alpha=0.85)

        # forged passed is 0 everywhere
        all_xs = sorted({r['forged_pct'] for r in rows})
        ax.plot(all_xs, [0] * len(all_xs), marker='x', linestyle=':',
                linewidth=1.4, markersize=7, color='#2a2a2a')

        # inline role labels; legend only has sizes and the two ~0 series
        ax.text(62, 146, 'offered', fontsize=10, color='#2ca02c',
                ha='center', va='top')
        fwd_label = ax.text(35, 97, 'forwarded', fontsize=9, color='#2ca02c',
                            rotation_mode='anchor', ha='center', va='bottom')
        ax.text(3, 77, 'offered', fontsize=10, color='#1f77b4',
                ha='left', va='bottom')

        # the shaded gap is the dropped forged traffic
        ax.text(82, 108, 'all forged\ndropped', fontsize=8.5, color='#444',
                ha='center', va='center', fontstyle='italic', linespacing=0.95)

        from matplotlib.lines import Line2D
        forged_proxy = Line2D([0], [0], linestyle='None', marker='x',
                              color='#2a2a2a', markersize=7,
                              markeredgewidth=1.8, label='forged passed = 0')
        legit_proxy  = Line2D([0], [0], linestyle='None', marker='+',
                              color='#555', markersize=8,
                              markeredgewidth=1.8, label='legit dropped at NIC')

        ax.set_xlabel('forged fraction (%)', fontsize=12)
        ax.set_ylabel('Mpps', fontsize=12)
        ax.tick_params(axis='both', labelsize=9)
        ax.grid(True, linestyle=':', alpha=0.55)
        ax.set_xticks([1, 5, 20, 50, 80, 99])
        # 1 and 5 labels overlap, hide the 5
        ax.set_xticklabels(['1', '', '20', '50', '80', '99'])
        # 88 fits 256/1500 B, 92 B goes up to ~150 Mpps
        ymax = max(r['lg_tx_pps'] for r in rows) / 1e6
        ax.set_ylim(-4, max(88, 1.08 * ymax))
        ax.legend(handles=offered_lines + [forged_proxy, legit_proxy],
                  loc='upper center', bbox_to_anchor=(0.5, -0.32),
                  fontsize=8.5, framealpha=0.95, ncol=2,
                  handlelength=1.6, borderpad=0.3, labelspacing=0.3,
                  columnspacing=1.2)
        fig.tight_layout(pad=0.3)
        # rotate 'forwarded' along the 92 B 20->50% segment, after layout
        fwd = {r['forged_pct']: r['lg_rx_pps'] / 1e6
               for r in rows if r['packet_size'] == 92}
        (x0, y0), (x1, y1) = ax.transData.transform([(20, fwd[20]), (50, fwd[50])])
        fwd_label.set_rotation(math.degrees(math.atan2(y1 - y0, x1 - x0)))
        out = results_dir / f'triage.{ext}'
        fig.savefig(out, dpi=200, bbox_inches='tight')
        print(f'wrote {out}')


if __name__ == '__main__':
    results_dir = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join(os.path.dirname(__file__), 'results')
    main(results_dir)
