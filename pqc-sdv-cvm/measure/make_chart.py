#!/usr/bin/env python3
"""
make_chart.py <runs_dir> <output.png>

Reads all runs/*/metrics.json, produces a 2x2 bar chart:
  total bytes  |  server→client bytes
  duration ms  |  TCP segments per handshake
"""
import sys
import json
import os
import glob

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

if len(sys.argv) != 3:
    print("usage: make_chart.py <runs_dir> <output.png>", file=sys.stderr)
    sys.exit(1)

runs_dir, output = sys.argv[1], sys.argv[2]

ORDER = [
    ("classical", "x25519"),
    ("classical", "x25519mlkem768"),
    ("mixed", "x25519mlkem768"),
    ("pqc", "x25519mlkem768"),
]


def labelize(chain, kem):
    return f"{chain}\n{kem}"


def medians_for(metrics_by_key, field):
    vals = []
    for k in ORDER:
        m = metrics_by_key.get(k)
        if m is None or m.get(field) is None:
            vals.append(0)
        else:
            vals.append(m[field]["median"])
    return vals


metrics_files = sorted(glob.glob(os.path.join(runs_dir, "*/metrics.json")))
metrics_by_key = {}
for mf in metrics_files:
    with open(mf) as fh:
        m = json.load(fh)
        metrics_by_key[(m["chain"], m["kem"])] = m

labels = [labelize(c, k) for c, k in ORDER]
total = medians_for(metrics_by_key, "handshake_total_bytes")
s2c = medians_for(metrics_by_key, "handshake_s2c_bytes")
dur = medians_for(metrics_by_key, "handshake_duration_ms")
segs = medians_for(metrics_by_key, "tcp_segments_per_session")

BAR = "#3B6FB5"
HIGHLIGHT = "#9050B5"
colors = [BAR, HIGHLIGHT, BAR, BAR]

fig, axes = plt.subplots(2, 2, figsize=(14, 9))
fig.suptitle(
    "PQC TLS into an Azure SEV-SNP CVM — handshake cost",
    fontsize=13,
    fontweight="bold",
    y=0.995,
)


def annotate(ax, vals, fmt="{:,.0f}"):
    yloc = ax.get_ylim()[1]
    for i, v in enumerate(vals):
        ax.text(
            i,
            v + yloc * 0.02,
            fmt.format(v),
            ha="center",
            va="bottom",
            fontsize=9.5,
            fontweight="bold",
        )


ax = axes[0, 0]
ax.bar(labels, total, color=colors, edgecolor="#222", linewidth=0.5)
ax.set_title("Total handshake bytes", fontweight="bold")
ax.set_ylabel("bytes")
if max(total) > 0:
    ax.set_ylim(0, max(total) * 1.18)
annotate(ax, total)
ax.grid(axis="y", linewidth=0.3, alpha=0.5)
ax.set_axisbelow(True)

ax = axes[0, 1]
ax.bar(labels, s2c, color=colors, edgecolor="#222", linewidth=0.5)
ax.set_title("Server → client bytes (cert chain dominates)", fontweight="bold")
ax.set_ylabel("bytes")
if max(s2c) > 0:
    ax.set_ylim(0, max(s2c) * 1.18)
annotate(ax, s2c)
ax.grid(axis="y", linewidth=0.3, alpha=0.5)
ax.set_axisbelow(True)

ax = axes[1, 0]
ax.bar(labels, dur, color=colors, edgecolor="#222", linewidth=0.5)
ax.set_title("Handshake wall-clock (median)", fontweight="bold")
ax.set_ylabel("ms")
if max(dur) > 0:
    ax.set_ylim(0, max(dur) * 1.18)
annotate(ax, dur, fmt="{:.0f} ms")
ax.grid(axis="y", linewidth=0.3, alpha=0.5)
ax.set_axisbelow(True)

ax = axes[1, 1]
ax.bar(labels, segs, color=colors, edgecolor="#222", linewidth=0.5)
ax.set_title("TCP segments per handshake", fontweight="bold")
ax.set_ylabel("segments")
if max(segs) > 0:
    ax.set_ylim(0, max(segs) * 1.18)
annotate(ax, segs, fmt="{:.0f}")
ax.grid(axis="y", linewidth=0.3, alpha=0.5)
ax.set_axisbelow(True)

plt.tight_layout(rect=[0, 0, 1, 0.96])
plt.savefig(output, dpi=140, bbox_inches="tight", facecolor="white")
print(f"wrote {output}")
