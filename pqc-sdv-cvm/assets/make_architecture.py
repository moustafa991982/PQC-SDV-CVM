#!/usr/bin/env python3
"""Generate architecture.png - clean version."""
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
import matplotlib.patches as mpatches

fig, ax = plt.subplots(figsize=(16, 11))
ax.set_xlim(0, 100)
ax.set_ylim(0, 80)
ax.axis('off')

LAPTOP = '#3B6FB5'
AZURE = '#0F6E56'
CVM = '#1E3A5F'
SVC = '#B5853A'
GRAY = '#777777'

def region(x, y, w, h, color, title, sub=None):
    rect = FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.2",
                          linewidth=1.5, edgecolor=color,
                          facecolor=color, alpha=0.05)
    ax.add_patch(rect)
    ax.text(x + 0.6, y + h - 0.7, title, fontsize=12, fontweight='bold',
            color=color, va='top')
    if sub:
        ax.text(x + 0.6, y + h - 2.0, sub, fontsize=8.5,
                color=color, va='top', style='italic')

def box(x, y, w, h, label, color, sub=None, fsize=9.5):
    rect = FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.12",
                          linewidth=1.1, edgecolor=color,
                          facecolor='white')
    ax.add_patch(rect)
    if sub:
        ax.text(x + w / 2, y + h * 0.65, label, ha='center', va='center',
                fontsize=fsize, fontweight='bold', color=color)
        ax.text(x + w / 2, y + h * 0.30, sub, ha='center', va='center',
                fontsize=fsize - 2, color=color)
    else:
        ax.text(x + w / 2, y + h / 2, label, ha='center', va='center',
                fontsize=fsize, fontweight='bold', color=color)

def arrow(x1, y1, x2, y2, color='#444', label=None, offset=(0, 0),
          lw=1.4, style='-|>', ls='-'):
    a = FancyArrowPatch((x1, y1), (x2, y2),
                        arrowstyle=style, color=color, lw=lw,
                        mutation_scale=15, linestyle=ls,
                        zorder=5)
    ax.add_patch(a)
    if label:
        tx, ty = (x1 + x2) / 2 + offset[0], (y1 + y2) / 2 + offset[1]
        ax.text(tx, ty, label, fontsize=8, color=color,
                ha='center', va='center',
                bbox=dict(boxstyle="round,pad=0.25", fc='white',
                          ec='none', alpha=0.95))

ax.text(50, 78, "PQC-SDV-CVM: end-to-end architecture",
        fontsize=16, fontweight='bold', ha='center', color='#222')
ax.text(50, 76.5,
        "Post-quantum TLS to an Azure SEV-SNP confidential VM, with SKR-gated key release and blob-served cert chains",
        fontsize=10, ha='center', style='italic', color='#666')

region(1.5, 4, 28, 70, LAPTOP, "Laptop side",
       "operator + simulated VCU + measurement harness")

box(3.5, 64, 24, 7, "Bash + az CLI orchestrator", LAPTOP,
    "scripts/00..04 + 99_teardown")

box(3.5, 54, 24, 7, "OpenSSL 3.5 (host)", LAPTOP,
    "builds 3 cert chains")

box(3.5, 42, 24, 9, "QEMU VCU", LAPTOP,
    "Ubuntu 24.04 amd64 + KVM\nOpenSSL 3.5 client + tshark")

box(3.5, 30, 24, 8, "Measurement harness", LAPTOP,
    "make scenario × 4 → metrics.json")

box(3.5, 18, 24, 8, "Output artifacts", LAPTOP,
    "results.png + results.md")

box(3.5, 8, 24, 6, "Operator", LAPTOP,
    "drives the demo")

region(32, 4, 67, 70, AZURE, "Azure (West Europe)",
       "rg-pqc-sdv-demo")

box(36, 62, 28, 11, "Confidential VM (SEV-SNP)", CVM,
    "Standard_DC2as_v5 • Ubuntu 22.04\nsystem-assigned managed identity\nAMD memory encryption ACTIVE",
    fsize=9.5)

box(38, 49, 24, 9, "nginx + OpenSSL 3.5", CVM,
    "TLS 1.3 on :443\nactive chain via symlinks")

box(38, 37, 24, 9, "/etc/pqc-sdv/", CVM,
    "keys/  (unwrapped, RAM)\ncerts/  (public, blob source)")

box(38, 25, 24, 9, "fetch-skr-key.py", CVM,
    "Python • managed identity\norchestrates key + cert load")

box(70, 64, 27, 8, "Microsoft Azure Attestation", SVC,
    "SEV-SNP report → signed JWT")

box(70, 51, 27, 11, "Azure Key Vault Premium", SVC,
    "wrap-key-<chain>  (SKR-gated)\nleafkey-<chain>-pem  (secrets)\nML-KEM-1024 wrap + RBAC")

box(70, 36, 27, 11, "Azure Blob Storage", SVC,
    "3 cert chains as PEM blobs\n~3 / 14 / 28 KB\nRBAC: Storage Blob Data Reader")

box(70, 22, 27, 9, "NSG + Public IP", SVC,
    "TCP/443 + TCP/22\nsource-restricted to laptop")

box(70, 10, 27, 8, "Resource group", SVC,
    "tears down in 99_teardown.sh")

arrow(27.5, 67, 36, 67, color=GRAY, ls='--',
      label='SSH', offset=(0, 0.6), lw=1.0)

arrow(27.5, 46, 36, 53, color='#9050B5', ls='-',
      label='hybrid PQC TLS 1.3\n(X25519MLKEM768)', offset=(-2, 3),
      lw=1.8)

arrow(50, 62, 50, 58, color=CVM, lw=1.0, style='-|>')
arrow(50, 49, 50, 46, color=CVM, lw=1.0, style='-|>')
arrow(50, 37, 50, 34, color=CVM, lw=1.0, style='-|>')

arrow(62, 30, 70, 68, color=CVM,
      label='[1] attest (skipped)', offset=(0, -1), ls=':')

arrow(70, 66, 64, 31, color=SVC,
      label='[2] JWT (skipped)', offset=(-1.5, 7), ls=':')

arrow(62, 28.5, 70, 58, color=CVM,
      label='[3] release_key', offset=(-1, 1.5))

arrow(70, 53, 64, 27, color=SVC,
      label='[4] wrap key', offset=(1, -2))

arrow(62, 26, 70, 44, color=CVM,
      label='[5] get_blob', offset=(-1, -1.5))

arrow(70, 38, 64, 25, color=SVC,
      label='[6] cert chain', offset=(1, -1))

ax.text(31, 2.5, "Laptop ↔ Azure: public internet (~80 ms RTT Cairo → West Europe)",
        fontsize=8.5, color=GRAY, style='italic', ha='left')

legend_items = [
    mpatches.Patch(color=LAPTOP, alpha=0.25, label='Laptop'),
    mpatches.Patch(color=AZURE, alpha=0.25, label='Azure (West Europe)'),
    mpatches.Patch(color=CVM, alpha=0.6, label='Confidential VM (TEE)'),
    mpatches.Patch(color=SVC, alpha=0.6, label='Azure services'),
]
ax.legend(handles=legend_items, loc='upper center',
          bbox_to_anchor=(0.5, 0.04), ncol=4,
          frameon=False, fontsize=10)

plt.tight_layout()
plt.savefig('/home/claude/pqc-sdv-cvm-github/assets/architecture.png',
            dpi=140, bbox_inches='tight', facecolor='white')
print("wrote architecture.png")
