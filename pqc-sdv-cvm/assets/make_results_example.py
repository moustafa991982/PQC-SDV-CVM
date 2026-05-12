#!/usr/bin/env python3
"""Generate results-example.png with the numbers actually measured."""
import matplotlib.pyplot as plt
import numpy as np

fig, axes = plt.subplots(2, 2, figsize=(14, 9))
fig.suptitle("PQC TLS into an Azure SEV-SNP CVM — measured handshake cost\n"
             "20 handshakes per scenario, Cairo laptop → West Europe CVM",
             fontsize=13, fontweight='bold', y=0.995)

labels = ['classical\n+ x25519',
          'classical\n+ x25519mlkem768',
          'mixed\n+ x25519mlkem768',
          'pqc\n+ x25519mlkem768']

total_bytes = [3923, 6284, 23924, 27095]
s2c_bytes = [3124, 4255, 21024, 25024]
duration_ms = [305, 196, 263, 260]
segments = [16, 18, 42, 42]

BAR_COLOR = '#3B6FB5'
HIGHLIGHT_COLOR = '#9050B5'
colors_bars = [BAR_COLOR, HIGHLIGHT_COLOR, BAR_COLOR, BAR_COLOR]

def annotate_bars(ax, vals, fmt='{:,.0f}', y_offset_factor=0.02):
    yloc = ax.get_ylim()[1]
    for i, v in enumerate(vals):
        ax.text(i, v + yloc * y_offset_factor, fmt.format(v),
                ha='center', va='bottom', fontsize=9.5, fontweight='bold')

ax = axes[0, 0]
ax.bar(labels, total_bytes, color=colors_bars, edgecolor='#222', linewidth=0.5)
ax.set_title("Total handshake bytes (median)", fontsize=11, fontweight='bold')
ax.set_ylabel("bytes")
ax.set_ylim(0, max(total_bytes) * 1.18)
annotate_bars(ax, total_bytes)
ax.grid(axis='y', linewidth=0.3, alpha=0.5)
ax.set_axisbelow(True)

ax = axes[0, 1]
ax.bar(labels, s2c_bytes, color=colors_bars, edgecolor='#222', linewidth=0.5)
ax.set_title("Server → client bytes (cert chain dominates)",
             fontsize=11, fontweight='bold')
ax.set_ylabel("bytes")
ax.set_ylim(0, max(s2c_bytes) * 1.18)
annotate_bars(ax, s2c_bytes)
ax.grid(axis='y', linewidth=0.3, alpha=0.5)
ax.set_axisbelow(True)

ax = axes[1, 0]
ax.bar(labels, duration_ms, color=colors_bars, edgecolor='#222', linewidth=0.5)
ax.set_title("Wall-clock duration (median)", fontsize=11, fontweight='bold')
ax.set_ylabel("ms")
ax.set_ylim(0, max(duration_ms) * 1.18)
annotate_bars(ax, duration_ms, fmt='{:.0f} ms')
ax.grid(axis='y', linewidth=0.3, alpha=0.5)
ax.set_axisbelow(True)

ax = axes[1, 1]
ax.bar(labels, segments, color=colors_bars, edgecolor='#222', linewidth=0.5)
ax.set_title("TCP segments per handshake", fontsize=11, fontweight='bold')
ax.set_ylabel("segments")
ax.set_ylim(0, max(segments) * 1.18)
annotate_bars(ax, segments, fmt='{:.0f}')
ax.grid(axis='y', linewidth=0.3, alpha=0.5)
ax.set_axisbelow(True)

axes[0, 0].text(1, max(total_bytes) * 1.04,
                "← hybrid KEM costs only +2.4 KB",
                fontsize=9, color=HIGHLIGHT_COLOR, ha='center',
                fontweight='bold')

plt.tight_layout(rect=[0, 0, 1, 0.96])
plt.savefig('/home/claude/pqc-sdv-cvm-github/assets/results-example.png',
            dpi=140, bbox_inches='tight', facecolor='white')
print("wrote results-example.png")
