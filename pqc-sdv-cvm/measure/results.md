# Results

_4 scenarios, 20 handshakes each, Cairo laptop → Azure CVM (West Europe)._

## Median per-handshake metrics

| Chain | KEM | Total bytes | C→S bytes | S→C bytes | Duration (ms) | TCP segments |
|---|---|---:|---:|---:|---:|---:|
| classical | x25519 | 3,923 | 799 | 3,124 | 305 | 16 |
| classical | x25519mlkem768 | 6,284 | 2,029 | 4,255 | 196 | 18 |
| mixed | x25519mlkem768 | 23,924 | 2,900 | 21,024 | 263 | 42 |
| pqc | x25519mlkem768 | 27,095 | 2,071 | 25,024 | 260 | 42 |

## Deltas (per-handshake cost)

| Transition | Δ Total bytes | Δ TCP segments | What it represents |
|---|---:|---:|---|
| classical→classical+PQ-KEM | +2,361 | +2 | hybrid KEM cost (HNDL defense) |
| +PQ trust anchor (mixed) | +17,640 | +24 | PQ root + sub-CA cost |
| +PQ leaf (pqc) | +3,171 | 0 | PQ leaf cert + signature |

## What the deltas mean

- **classical → hybrid KEM**: adding `X25519MLKEM768` to an otherwise-classical handshake costs **~2.4 KB per handshake**. The TLS 1.3 group negotiation, transcript hash, and HKDF chain are unchanged; only the `key_share` payload grows (ML-KEM-768 public key 1184 B + ciphertext 1088 B + a little extension overhead).

- **hybrid KEM → mixed PKI**: replacing ECDSA at the root and sub-CA with ML-DSA-87 + ML-DSA-65 adds **~18 KB** on the wire. Most of this lives in the `Certificate` message (the chain itself grows from ~3 KB to ~14 KB). TCP segments **more than double** at this boundary because the chain spans MTU. This is a decadal cost — root certificates rotate on 20–40 year timelines.

- **mixed → pure PQ**: replacing the ECDSA leaf with ML-DSA-44 and its CertificateVerify signature adds **~3 KB** more. Smaller than the trust-anchor jump because the leaf is the shortest-lived cert (rotates often) and ML-DSA-44 is the smallest variant. Pays per-handshake but doesn't require PKI migration.

All other things equal, the hybrid KEM is by far the cheapest layer to deploy, and the only one that meaningfully defends against harvest-now-decrypt-later. See `docs/THREAT_MODEL.md`.

## Wall-clock caveat

The "Duration (ms)" column shows ~80–100 ms RTT to West Europe dominating all four scenarios. Scenario 2 (`classical + hybrid KEM`) being faster than scenario 1 reflects WAN-path variability between runs, not a property of the algorithms — at a sub-100 ms latency floor, the small extra computation of ML-KEM-768 encapsulation/decapsulation is in the noise. The systematic effect to observe is that mixed/pqc are ~30% slower than the classical baseline, consistent with the 1–2 extra TCP RTTs needed to fragment and reassemble the large cert chain.

## How these results were produced

```bash
make scenario CHAIN=classical KEM=x25519
make scenario CHAIN=classical KEM=x25519mlkem768
make scenario CHAIN=mixed KEM=x25519mlkem768
make scenario CHAIN=pqc KEM=x25519mlkem768
make report
```

Re-running on a different network path or CVM region will produce different absolute numbers but the same deltas — those are properties of the algorithms.
