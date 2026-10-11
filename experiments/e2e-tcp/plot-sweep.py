#!/usr/bin/env python3
"""Plot HTTP latency CDF tails for the e2e-tcp modes."""
import argparse
import glob
import json
import os
import re
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import LogLocator, ScalarFormatter
import numpy as np


MODES = [
    ("raw_no_attack",        "raw forwarding (no AB pipeline)"),
    ("validate_no_attack",   "encap + validate + strip, no attack"),
    ("validate_with_attack", "encap + validate + strip, forged attack"),
]
# short labels for the p99.9 callouts
MODE_SHORT_LABELS = {
    "raw_no_attack":        "raw forwarding",
    "validate_no_attack":   "validate + strip, no attack",
    "validate_with_attack": "validate + strip, under attack",
}
MODE_COLORS = {
    "raw_no_attack":        "#6e6e6e",
    "validate_no_attack":   "#0072B2",
    "validate_with_attack": "#D55E00",
}
MODE_LINESTYLE = {
    "raw_no_attack":        (0, (4, 2)),   # dashed
    "validate_no_attack":   "-",
    "validate_with_attack": "-",
}


def parse_spectrum(path):
    pts = []
    with open(path) as f:
        in_section = False
        for line in f:
            if "Detailed Percentile spectrum" in line:
                in_section = True
                continue
            if not in_section:
                continue
            if line.startswith("#[") or line.startswith("---"):
                break
            m = re.match(r"\s*([\d.]+)\s+([\d.]+)\s+\d+\s+\S+\s*$", line)
            if not m:
                continue
            lat = float(m.group(1))
            pct = float(m.group(2))
            if pct < 1.0:
                pts.append((pct, lat))
    return pts


def percentile_to_x(p):
    return -np.log10(1.0 - np.asarray(p))


def collect(results_dir, mode_key):
    paths = sorted(glob.glob(os.path.join(results_dir, f"{mode_key}.iter*.txt")))
    out = []
    for p in paths:
        s = parse_spectrum(p)
        if s:
            out.append(np.array(s))
    return out


def parse_reqs(path):
    """wrk2 prints a single 'Requests/sec:  19925.09' summary line."""
    with open(path) as f:
        for line in f:
            m = re.match(r"\s*Requests/sec:\s*([\d.]+)", line)
            if m:
                return float(m.group(1))
    return None


def collect_reqs(results_dir, mode_key):
    out = []
    for p in sorted(glob.glob(os.path.join(results_dir, f"{mode_key}.iter*.txt"))):
        r = parse_reqs(p)
        if r is not None:
            out.append(r)
    return out


def print_params(results_dirs, sizes, key_pcts=(0.5, 0.99, 0.999, 0.9999)):
    """Print per-mode latency percentiles and wrk2 request rates for the paper."""
    kp = np.array(key_pcts)
    print("\n=== e2e parameters (results section) ===")
    for rdir, size in zip(results_dirs, sizes):
        print(f"-- {size} B attack-packet size --")
        for mode_key, _ in MODES:
            iters = collect(rdir, mode_key)
            if not iters:
                continue
            med, _, _, _ = aggregate(iters, kp)
            cols = "  ".join(f"{p}={v:.2f}" for p, v in
                             zip(["p50", "p99", "p99.9", "p99.99"], med))
            print(f"  {mode_key:<22} {cols} ms  (n={len(iters)})")
    noatk, atk = [], []
    print("  -- sustained wrk2 request rate (req/s) --")
    for rdir, size in zip(results_dirs, sizes):
        for mode_key, _ in MODES:
            rs = collect_reqs(rdir, mode_key)
            if not rs:
                continue
            a = np.array(rs)
            print(f"    {size}B {mode_key:<22} median={np.median(a):.0f} "
                  f"std={a.std():.0f} (n={len(a)})")
            (atk if mode_key == "validate_with_attack" else noatk).extend(rs)
    if noatk:
        a = np.array(noatk)
        print(f"  no-attack (raw+validate, all sizes): "
              f"median={np.median(a):.0f} std={a.std():.0f} (n={len(a)})")
    if atk:
        a = np.array(atk)
        print(f"  under-attack (all sizes):            "
              f"median={np.median(a):.0f} std={a.std():.0f} (n={len(a)})")
    print()


def aggregate(iters, common_pcts):
    """Median, 25th, 75th percentile across iterations on a shared grid."""
    interp = []
    for arr in iters:
        pcts, lats = arr[:, 0], arr[:, 1]
        order = np.argsort(pcts)
        interp.append(np.interp(common_pcts, pcts[order], lats[order]))
    s = np.vstack(interp)
    return (np.median(s, axis=0),
            np.percentile(s, 25, axis=0),
            np.percentile(s, 75, axis=0),
            s.max(axis=0))


def plot(results_dirs, sizes, out_path, key_pcts=(0.5, 0.99, 0.999, 0.9999)):
    plt.rcParams.update({
        "font.family": "DejaVu Serif",
        "font.size": 12,
        "axes.labelsize": 13,
        "axes.titlesize": 13,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "axes.linewidth": 0.8,
        "xtick.major.width": 0.8,
        "ytick.major.width": 0.8,
        "legend.frameon": False,
    })

    common_pcts = 1 - np.logspace(0, -5.5, 400)
    common_x = percentile_to_x(common_pcts)
    tick_pcts = np.array([0.5, 0.9, 0.99, 0.999, 0.9999, 0.99999])
    tick_labels = ["50%", "90%", "99%", "99.9%", "99.99%", "99.999%"]

    fig, axes = plt.subplots(1, len(results_dirs), figsize=(5.5 * len(results_dirs), 3.2),
                             sharey=True)
    if len(results_dirs) == 1:
        axes = [axes]

    n_iters_overall = 0
    annotation_pct = 0.999  # call out p99.9 explicitly
    for ax, rdir, size in zip(axes, results_dirs, sizes):
        max_iters = 0
        for mode_key, mode_label in MODES:
            iters = collect(rdir, mode_key)
            if not iters:
                continue
            max_iters = max(max_iters, len(iters))
            median, q1, q3, _ = aggregate(iters, common_pcts)
            color = MODE_COLORS[mode_key]
            ls = MODE_LINESTYLE[mode_key]
            ax.fill_between(common_x, q1, q3, color=color, alpha=0.18, lw=0,
                            zorder=2)
            ax.plot(common_x, median, color=color, lw=2.2, ls=ls,
                    label=mode_label, zorder=4)
        n_iters_overall = max(n_iters_overall, max_iters)
        ax.set_title(panel_title(rdir, size), fontsize=13)
        ax.set_xlabel("percentile of HTTP request latency")
        ax.set_xticks(percentile_to_x(tick_pcts))
        ax.set_xticklabels(tick_labels, fontsize=11)
        ax.set_yscale("log")

        major_ticks = [1, 2, 5, 10]
        ax.set_yticks(major_ticks)
        ax.set_yticklabels([f"{v}" for v in major_ticks])
        ax.yaxis.set_minor_locator(LogLocator(base=10,
            subs=(2, 3, 4, 5, 6, 7, 8, 9), numticks=20))
        ax.grid(True, which="major", alpha=0.30, lw=0.5)
        ax.grid(True, which="minor", alpha=0.10, lw=0.4)
        ax.set_xlim(0, percentile_to_x(0.99999))

    for ax in axes:
        ax.set_ylim(0.7, 12.0)

    axes[0].set_ylabel("latency (ms, log scale)")

    # p99.9 median and IQR per mode
    for ax, rdir, size in zip(axes, results_dirs, sizes):
        rows = []
        for mode_key, mode_label in MODES:
            iters = collect(rdir, mode_key)
            if not iters:
                continue
            median, q1, q3, _ = aggregate(iters, np.array([annotation_pct]))
            rows.append((MODE_SHORT_LABELS[mode_key],
                         MODE_COLORS[mode_key],
                         float(median[0]), float(q1[0]), float(q3[0])))
        # lower right is empty below the curves
        x0 = 0.97
        y0 = 0.40
        ax.text(x0, y0, "p99.9 (median, IQR):", transform=ax.transAxes,
                fontsize=10, color="#222", va="top", ha="right")
        for i, (lbl, col, med, q1, q3) in enumerate(rows):
            ax.text(x0, y0 - 0.09 - 0.08 * i,
                    f"{lbl}   {med:.2f} ms  [{q1:.2f}-{q3:.2f}]",
                    transform=ax.transAxes, fontsize=10, color=col,
                    va="top", ha="right")

    # Single shared legend below the panels
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="lower center", ncol=len(MODES),
               bbox_to_anchor=(0.5, -0.04), fontsize=11,
               handlelength=2.4)

    fig.tight_layout(rect=[0, 0.07, 1, 1.00])
    fig.savefig(out_path, dpi=200, bbox_inches="tight")
    print(f"wrote {out_path}")


def attack_mpps(results_dir, uplink=3):
    """Offered attack rate, measured at the validator NIC (received + dropped)."""
    st = os.path.join(results_dir, "filter_stats_validate_with_attack.log")
    tel = os.path.join(results_dir, "filter_tel_validate_with_attack.json")
    if not (os.path.exists(st) and os.path.exists(tel)):
        return None
    secs = sum(1 for line in open(st)
               if int(re.search(r"worker_rx=(\d+)", line).group(1)) > 1e7)
    ports = [json.loads(l)["/ethdev/stats"] for l in open(tel) if '"/ethdev/stats"' in l]
    pkts = sum(p["ipackets"] + p["imissed"] for i, p in enumerate(ports) if i != uplink)
    return pkts / secs / 1e6 if secs else None


def panel_title(results_dir, size):
    m = attack_mpps(results_dir)
    return f"{size} B attack packets" + (f", {m:.0f} Mpps" if m else "")


def main():
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--out", default=os.path.join(here, "results", "e2e_latency.pdf"))
    # 512 B is also collected but left out: it shows nothing beyond 90 B and 256 B.
    ap.add_argument("--dirs", nargs="+",
                    default=[os.path.join(here, "results", s) for s in ("90", "256")])
    ap.add_argument("--sizes", nargs="+", default=["90", "256"])
    args = ap.parse_args()
    if len(args.dirs) != len(args.sizes):
        sys.exit("--dirs and --sizes lengths must match")
    plot(args.dirs, args.sizes, args.out)
    print_params(args.dirs, args.sizes)


if __name__ == "__main__":
    main()
