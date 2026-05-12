#!/usr/bin/env python3
"""Generate handshake-sequence.png - TLS 1.3 with hybrid PQC."""
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle

fig, ax = plt.subplots(figsize=(15, 11))
ax.set_xlim(0, 100)
ax.set_ylim(0, 100)
ax.axis('off')

CLIENT = '#3B6FB5'
SERVER = '#0F6E56'
DOWNLOAD = '#B5853A'
HIGHLIGHT = '#9050B5'

ax.text(50, 97, "TLS 1.3 handshake with hybrid PQC key exchange (X25519MLKEM768)",
        fontsize=14, fontweight='bold', ha='center')
ax.text(50, 95.3,
        "channel confidentiality is quantum-safe; identity authenticity depends on the cert chain",
        fontsize=10, ha='center', style='italic', color='#666')

actor_x = {'C': 18, 'S': 82}
ax.add_patch(FancyBboxPatch((actor_x['C'] - 8, 88), 16, 5,
                            boxstyle="round,pad=0.15", linewidth=1.5,
                            edgecolor=CLIENT, facecolor=CLIENT, alpha=0.12))
ax.text(actor_x['C'], 90.5, "Client (QEMU VCU)", fontsize=11,
        fontweight='bold', color=CLIENT, ha='center')

ax.add_patch(FancyBboxPatch((actor_x['S'] - 8, 88), 16, 5,
                            boxstyle="round,pad=0.15", linewidth=1.5,
                            edgecolor=SERVER, facecolor=SERVER, alpha=0.12))
ax.text(actor_x['S'], 90.5, "Server (Azure CVM)", fontsize=11,
        fontweight='bold', color=SERVER, ha='center')

ax.plot([actor_x['C'], actor_x['C']], [10, 88],
        color='#999', linestyle='--', linewidth=0.8, zorder=1)
ax.plot([actor_x['S'], actor_x['S']], [10, 88],
        color='#999', linestyle='--', linewidth=0.8, zorder=1)

def msg(y, src, dst, label, label2=None, color='#222', size_note=None,
        thick=False):
    sx, sy = actor_x[src], y
    dx, dy = actor_x[dst], y
    a = FancyArrowPatch((sx, sy), (dx, dy),
                        arrowstyle='-|>', color=color,
                        lw=2.0 if thick else 1.4,
                        mutation_scale=14, zorder=5)
    ax.add_patch(a)
    mid_x = (sx + dx) / 2
    ax.text(mid_x, y + 1.0, label, fontsize=9.5, color=color,
            ha='center', va='bottom', fontweight='bold')
    if label2:
        ax.text(mid_x, y - 1.2, label2, fontsize=8, color=color,
                ha='center', va='top', style='italic')
    if size_note:
        ax.text(dx + 0.5 if dst == 'S' else sx - 0.5, y, size_note,
                fontsize=7.5, color=color,
                ha='left' if dst == 'S' else 'right',
                va='center',
                bbox=dict(boxstyle="round,pad=0.15", fc='#fffceb',
                          ec='none'))

def note(y, x, txt, color='#444', halign='center', valign='center'):
    ax.text(x, y, txt, fontsize=8.5, color=color, style='italic',
            ha=halign, va=valign,
            bbox=dict(boxstyle="round,pad=0.3", fc='#fafafa', ec=color,
                      alpha=0.8))

note(83, actor_x['C'], "generate X25519 + ML-KEM-768 ephemerals",
     color=CLIENT)

msg(78, 'C', 'S',
    "ClientHello",
    "key_share = X25519_pk ‖ ML-KEM-768_pk",
    color=CLIENT, size_note="+1216 B")

note(72, actor_x['S'],
     "X25519: derive ephemeral, compute ss_ec\n"
     "ML-KEM: encapsulate(pk) → ct + ss_pq",
     color=SERVER)

msg(64, 'S', 'C',
    "ServerHello",
    "key_share = X25519_pk ‖ ML-KEM_ct",
    color=SERVER, size_note="+1120 B")

ax.add_patch(FancyBboxPatch((22, 53), 56, 6, boxstyle="round,pad=0.2",
                            linewidth=1.5, edgecolor=HIGHLIGHT,
                            facecolor=HIGHLIGHT, alpha=0.10))
ax.text(50, 56,
        "both sides:  shared_secret = ss_ec ‖ ss_pq  →  HKDF-Extract → handshake_secret",
        fontsize=10.5, fontweight='bold', color=HIGHLIGHT, ha='center')

msg(48, 'S', 'C', "EncryptedExtensions + Certificate",
    "cert chain encrypted with handshake key",
    color=SERVER, size_note="varies")

msg(42, 'S', 'C', "CertificateVerify",
    "signature over transcript (ECDSA or ML-DSA)",
    color=SERVER)

msg(36, 'S', 'C', "Finished",
    "HMAC over transcript",
    color=SERVER)

msg(30, 'C', 'S', "Finished",
    "HMAC over transcript",
    color=CLIENT)

ax.add_patch(Rectangle((actor_x['C'], 23), actor_x['S'] - actor_x['C'], 3,
                       facecolor='#3B6D11', alpha=0.6, zorder=4))
ax.text(50, 24.5, "Application data — AES-256-GCM, keys derived from handshake_secret",
        fontsize=9.5, color='white', fontweight='bold', ha='center', va='center',
        zorder=6)

ax.text(50, 18, "What each defense protects against:",
        fontsize=10.5, fontweight='bold', ha='center', color='#333')

ax.add_patch(FancyBboxPatch((4, 9), 28, 7, boxstyle="round,pad=0.15",
                            linewidth=1, edgecolor=HIGHLIGHT,
                            facecolor=HIGHLIGHT, alpha=0.10))
ax.text(18, 14, "Channel confidentiality", fontsize=9.5,
        fontweight='bold', color=HIGHLIGHT, ha='center')
ax.text(18, 11.5,
        "hybrid KEM defeats\nharvest-now-decrypt-later",
        fontsize=8, color=HIGHLIGHT, ha='center', style='italic')

ax.add_patch(FancyBboxPatch((36, 9), 28, 7, boxstyle="round,pad=0.15",
                            linewidth=1, edgecolor=SERVER,
                            facecolor=SERVER, alpha=0.10))
ax.text(50, 14, "Identity authenticity", fontsize=9.5,
        fontweight='bold', color=SERVER, ha='center')
ax.text(50, 11.5,
        "ML-DSA cert chain defeats\nQ-day root forgery",
        fontsize=8, color=SERVER, ha='center', style='italic')

ax.add_patch(FancyBboxPatch((68, 9), 28, 7, boxstyle="round,pad=0.15",
                            linewidth=1, edgecolor=DOWNLOAD,
                            facecolor=DOWNLOAD, alpha=0.10))
ax.text(82, 14, "Server-key custody", fontsize=9.5,
        fontweight='bold', color=DOWNLOAD, ha='center')
ax.text(82, 11.5,
        "CVM + SKR defeat\ncloud-insider RAM read",
        fontsize=8, color=DOWNLOAD, ha='center', style='italic')

plt.tight_layout()
plt.savefig('/home/claude/pqc-sdv-cvm-github/assets/handshake-sequence.png',
            dpi=140, bbox_inches='tight', facecolor='white')
print("wrote handshake-sequence.png")
