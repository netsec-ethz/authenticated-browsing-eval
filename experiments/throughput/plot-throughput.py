#!/usr/bin/env python3
"""Plot AB validator throughput from the MoonGen logs."""
import glob
import os
import re
import numpy as np
import matplotlib.pyplot as plt

plt.rcParams.update({'font.family': 'DejaVu Serif'})

FOLDER = os.path.join(os.path.dirname(__file__), "results")
OUT_BASE = os.path.join(os.path.dirname(__file__), "throughput")

cores = np.array([4, 8, 16, 24, 32])
packet_size = np.array([90, 256, 512, 1024, 1500])

# Final-summary RX line: "RX...: ... Mbit/s (NNN Mbit/s with framing), total"
SUMMARY_RE = re.compile(r"RX.*?\((\d+) Mbit/s with framing\), total")


def parse_run(path):
    with open(path) as f:
        fc = f.read()
    res = SUMMARY_RE.findall(fc)
    if len(res) < 4:
        raise RuntimeError(f"{path}: expected 4 RX summary lines, got {len(res)}")
    return sum(int(x) for x in res[-4:])


rates = np.array(
    [[parse_run(f"{FOLDER}/c{c}_pz{p}.lg.log") for p in packet_size] for c in cores]
).transpose()  # rates[pkt_idx][core_idx], total Mbit/s (with framing) across the 4 RX links


def _mpps(mbit, s):
    # +20 B per frame for preamble and IFG
    return mbit / ((s + 20) * 8)


# numbers for the paper, plus the first core count that hits ~160 Gb/s
SAT_GBPS = 159.0
print("\n=== throughput parameters (Results) ===")
for i, p in enumerate(packet_size):
    pts = "  ".join(
        f"{c}c={rates[i][j] / 1000:.1f}Gb/s/{_mpps(rates[i][j], p):.1f}Mpps"
        for j, c in enumerate(cores))
    print(f"{p:>4}B: {pts}")
for i, p in enumerate(packet_size):
    sat = next((c for j, c in enumerate(cores)
                if rates[i][j] / 1000 >= SAT_GBPS), None)
    print(f"  {p}B saturates (>={SAT_GBPS:.0f} Gb/s) at "
          + (f"{sat} cores" if sat else "not within sweep"))
print()

fig, ax = plt.subplots(figsize=(2.8, 2.4))
for i, r in enumerate(packet_size):
    ax.plot(cores, rates[i] / 1000, marker="x", linewidth=1.6,
            markersize=6, markeredgewidth=1.6, label=f"{r}\u202fB")
ax.set_ylim([0, 170])
ax.grid(True, linestyle=':', alpha=0.55)
ax.minorticks_on()
ax.set_xlabel("number of cores", fontsize=13)
ax.set_ylabel("throughput (Gbps)", fontsize=13)
ax.tick_params(axis='both', labelsize=11)
ax.legend(loc='lower right', fontsize=10, framealpha=0.5,
          title='packet size', title_fontsize=11, ncol=2,
          handlelength=1.6, borderpad=0.35, labelspacing=0.25,
          columnspacing=1.0)

fig.tight_layout(pad=0.3)
for ext in ('pdf', 'png'):
    out = f"{OUT_BASE}.{ext}"
    fig.savefig(out, dpi=200, bbox_inches='tight')
    print("wrote", out)
