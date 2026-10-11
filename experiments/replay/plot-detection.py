#!/usr/bin/env python3
"""Plot offered vs leaked replay pps over the replay fraction (log y, shaded gap = caught)."""
import csv
import math
import sys
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

plt.rcParams.update({'font.family': 'DejaVu Serif'})

results_dir = Path(sys.argv[1] if len(sys.argv) > 1 else
                   Path(__file__).parent / 'results')
rows = list(csv.DictReader(open(results_dir / 'replay.csv')))

packet_sizes = sorted({int(r['packet_size']) for r in rows})
colors = {92: '#2ca02c', 256: '#1f77b4', 1500: '#d62728'}

fig, ax = plt.subplots(figsize=(2.8, 2.4))
ax.set_xlim(-3, 102)

# colour = packet size, line style = offered/leaked
offered_lines = []
for pz in packet_sizes:
    sub = [r for r in rows if int(r['packet_size']) == pz]
    sub.sort(key=lambda r: int(r['replay_pct']))
    xs = [int(r['replay_pct'])    for r in sub]
    rx = [int(r['replay_rx_pps']) for r in sub]
    tx = [max(1, int(r['replay_tx_pps'])) for r in sub]
    c = colors[pz]
    ax.fill_between(xs, tx, rx, color=c, alpha=0.10, linewidth=0)
    line, = ax.plot(xs, rx, marker='o', linestyle='-',
                    linewidth=1.6, markersize=4, color=c,
                    label=f'{pz} B')
    offered_lines.append(line)
    ax.plot(xs, tx, marker='s', linestyle='--', linewidth=1.4,
            markersize=3.5, color=c)

ax.text(50, 4e4, 'caught by\ndedup table',
        fontsize=8.5, color='#2a2a2a', ha='center', va='center',
        fontstyle='italic', linespacing=0.95)

det_min = min(float(r['replay_detection_rate']) for r in rows)
det_max = max(float(r['replay_detection_rate']) for r in rows)
ax.text(0.03, 0.96,
        f'det ≥ {math.floor(det_min * 1e4) / 1e4:.4f}\nlegit FPR = 0',
        transform=ax.transAxes, fontsize=7.5, va='top', ha='left',
        bbox=dict(facecolor='white', edgecolor='gray',
                  boxstyle='round,pad=0.25', alpha=0.6))

ax.set_yscale('log')
ax.set_ylim(0.5, 1e9)
ax.set_xlabel('replay fraction (%)', fontsize=12)
ax.set_ylabel('replay pps (log)', fontsize=12)
ax.tick_params(axis='both', labelsize=9)
ax.grid(True, which='major', linestyle=':', alpha=0.55)
ax.grid(True, which='minor', linestyle=':', alpha=0.20)
ax.set_xticks([1, 5, 20, 50, 80, 99])
# narrow panel: the 1 and 5 labels collide, so drop the 5 label (tick stays)
ax.set_xticklabels(['1', '', '20', '50', '80', '99'])

# grey proxies for the offered/passed line styles
from matplotlib.lines import Line2D
offered_proxy = Line2D([0], [0], color='#555', linestyle='-',
                       linewidth=1.6, marker='o', markersize=4,
                       label='offered')
leaked_proxy  = Line2D([0], [0], color='#555', linestyle='--',
                       linewidth=1.4, marker='s', markersize=3.5,
                       label='passed')
ax.legend(handles=offered_lines + [offered_proxy, leaked_proxy],
          loc='upper center', bbox_to_anchor=(0.5, -0.30),
          fontsize=8.5, framealpha=0.95, ncol=3,
          handlelength=1.6, borderpad=0.3, labelspacing=0.3,
          columnspacing=1.0)

fig.tight_layout(pad=0.3)
for ext in ('pdf', 'png'):
    out = results_dir / f'detection.{ext}'
    fig.savefig(out, dpi=200, bbox_inches='tight')
    print(f'wrote {out}')
