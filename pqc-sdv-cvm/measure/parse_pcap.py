#!/usr/bin/env python3
"""
parse_pcap.py - extract per-handshake metrics from a pcap of N TLS handshakes.

Reads a pcap containing N back-to-back TLS handshakes (each in its own TCP
stream), uses tshark to extract:

  - per-flow byte counts (c2s, s2c, total) via `tshark -q -z conv,tcp`
  - per-flow TCP segment counts (same source)
  - per-flow wall-clock duration (first packet to last packet of each stream)

Emits a single JSON object with median / mean / p95 across all flows.

Robust to tshark's mixed unit suffixes (`bytes` for small flows, `kB` / `MB`
for larger ones).
"""
import sys
import json
import re
import subprocess
import statistics

if len(sys.argv) != 4:
    print("usage: parse_pcap.py <pcap> <chain> <kem>", file=sys.stderr)
    sys.exit(1)

pcap, chain, kem = sys.argv[1], sys.argv[2], sys.argv[3]


def sh(*args):
    return subprocess.check_output(args, stderr=subprocess.DEVNULL).decode()


UNIT = {
    "bytes": 1,
    "kB": 1000,
    "MB": 1_000_000,
    "kiB": 1024,
    "MiB": 1024 * 1024,
}


def to_bytes(num_str, unit):
    n = float(num_str.replace(",", ""))
    return int(round(n * UNIT.get(unit, 1)))


conv = sh("tshark", "-r", pcap, "-q", "-z", "conv,tcp")

sessions = []
for line in conv.splitlines():
    if "<->" not in line:
        continue
    # Each row in tshark's conv,tcp table has three "(\d+)\s+([\d,.]+)\s+(bytes|kB|...)"
    # triples in order: server→client, client→server, total
    pairs = re.findall(
        r"(\d+)\s+([\d,.]+)\s+(bytes|kB|MB|kiB|MiB)", line
    )
    if len(pairs) < 3:
        continue
    try:
        s2c_frames = int(pairs[0][0])
        s2c_bytes_ = to_bytes(pairs[0][1], pairs[0][2])
        c2s_frames = int(pairs[1][0])
        c2s_bytes_ = to_bytes(pairs[1][1], pairs[1][2])
        total_frames = int(pairs[2][0])
        total_bytes = to_bytes(pairs[2][1], pairs[2][2])
    except (ValueError, IndexError):
        continue
    if total_bytes < 500 or total_bytes > 500_000:
        continue
    sessions.append(
        {
            "c2s_bytes": c2s_bytes_,
            "s2c_bytes": s2c_bytes_,
            "total_bytes": total_bytes,
            "segs": total_frames,
        }
    )

# Wall-clock duration per stream: timestamp of first packet to last packet.
# Works regardless of what TLS records are present; doesn't rely on locating
# the first ApplicationData record (which can be too small to register).
dur_out = sh(
    "tshark", "-r", pcap, "-T", "fields",
    "-e", "tcp.stream", "-e", "frame.time_relative",
    "-Y", "tcp",
)
dur_state = {}
for line in dur_out.splitlines():
    parts = line.split("\t")
    if len(parts) < 2:
        continue
    sid, ts = parts
    if not sid or not ts:
        continue
    ts = float(ts)
    if sid not in dur_state:
        dur_state[sid] = {"start": ts, "end": ts}
    else:
        dur_state[sid]["end"] = ts

durations_ms = [
    (s["end"] - s["start"]) * 1000.0
    for s in dur_state.values()
    if s["end"] > s["start"]
]


def stats(xs):
    if not xs:
        return None
    return {
        "n": len(xs),
        "median": round(statistics.median(xs), 2),
        "mean": round(statistics.mean(xs), 2),
        "p95": round(statistics.quantiles(xs, n=20)[18], 2)
        if len(xs) >= 20
        else round(max(xs), 2),
    }


print(json.dumps(
    {
        "chain": chain,
        "kem": kem,
        "session_count": len(sessions),
        "handshake_total_bytes": stats([s["total_bytes"] for s in sessions]),
        "handshake_c2s_bytes": stats([s["c2s_bytes"] for s in sessions]),
        "handshake_s2c_bytes": stats([s["s2c_bytes"] for s in sessions]),
        "handshake_duration_ms": stats(durations_ms),
        "tcp_segments_per_session": stats([s["segs"] for s in sessions]),
    },
    indent=2,
))
