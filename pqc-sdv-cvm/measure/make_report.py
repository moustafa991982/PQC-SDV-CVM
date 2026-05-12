#!/usr/bin/env python3
"""
make_report.py <runs_dir>

Reads all runs/*/metrics.json and prints a markdown table summarizing them.
The output is the headline table for results.md.
"""
import sys
import json
import os
import glob

if len(sys.argv) != 2:
    print("usage: make_report.py <runs_dir>", file=sys.stderr)
    sys.exit(1)

runs_dir = sys.argv[1]
metrics_files = sorted(glob.glob(os.path.join(runs_dir, "*/metrics.json")))


def m_or_dash(d, field, key="median"):
    if d.get(field) is None:
        return "-"
    return f"{d[field][key]:,}"


metrics = []
for mf in metrics_files:
    with open(mf) as fh:
        metrics.append(json.load(fh))


ORDER = [
    ("classical", "x25519"),
    ("classical", "x25519mlkem768"),
    ("mixed", "x25519mlkem768"),
    ("pqc", "x25519mlkem768"),
]


def key_for(m):
    return (m["chain"], m["kem"])


metrics_by_key = {key_for(m): m for m in metrics}

print("# Results")
print()
print(f"_{len(metrics)} scenarios, 20 handshakes each, Cairo laptop → "
      "Azure CVM (West Europe)._")
print()
print("## Median per-handshake metrics")
print()
print("| Chain | KEM | Total bytes | C→S bytes | S→C bytes | "
      "Duration (ms) | TCP segments |")
print("|---|---|---:|---:|---:|---:|---:|")

for (chain, kem) in ORDER:
    m = metrics_by_key.get((chain, kem))
    if m is None:
        continue
    print(
        f"| {m['chain']} | {m['kem']} | "
        f"{m_or_dash(m, 'handshake_total_bytes')} | "
        f"{m_or_dash(m, 'handshake_c2s_bytes')} | "
        f"{m_or_dash(m, 'handshake_s2c_bytes')} | "
        f"{m_or_dash(m, 'handshake_duration_ms')} | "
        f"{m_or_dash(m, 'tcp_segments_per_session')} |"
    )

print()
print("## What the deltas mean")
print()
print("- Scenario 1 → 2: cost of hybrid PQC KEM with the same cert chain.")
print("- Scenario 2 → 3: cost of PQ-signing the trust anchor (root + sub-CA).")
print("- Scenario 3 → 4: cost of PQ-signing the leaf and its CertificateVerify.")
print()
print("All other things equal, the hybrid KEM is by far the cheapest layer "
      "to deploy, and the only one that meaningfully defends against "
      "harvest-now-decrypt-later. See `docs/THREAT_MODEL.md`.")
