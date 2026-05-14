# Performance and threat differentiation: classical vs hybrid vs pure PQC TLS

A single-document comparison of the four deployment configurations measured in this demo, on real Azure infrastructure over a real WAN path from Cairo to West Europe.

## Configuration recap

| Mode | Chain | OpenSSL `-groups` flag | Key exchange on the wire | Leaf cert signature |
|---|---|---|---|---|
| **Classic** | `classical` | `x25519` | X25519 alone | ECDSA-P256 |
| **Hybrid (KEM-only)** | `classical` | `x25519mlkem768` | X25519 + ML-KEM-768 concatenated | ECDSA-P256 |
| **Hybrid (with PQ trust anchor)** | `mixed` | `x25519mlkem768` | X25519 + ML-KEM-768 concatenated | ECDSA-P256 (ML-DSA root + sub-CA) |
| **Pure PQC** | `pqc` | `x25519mlkem768` | X25519 + ML-KEM-768 concatenated | ML-DSA-44 (ML-DSA chain) |

Note: "Classic" never appears with `x25519mlkem768` because using a PQ KEM is what makes it hybrid. "Hybrid" in this document refers specifically to the key exchange — the certificate chain can still be classical or PQ independently. That decoupling is the most important practical insight from the measurements.

## Measured per-handshake cost (20 handshakes per scenario, medians)

| Configuration | Total bytes | C→S bytes | S→C bytes | Duration (ms) | TCP segments |
|---|---:|---:|---:|---:|---:|
| Classical (x25519) | **3,923** | 799 | 3,124 | 305 | 16 |
| Classical + hybrid KEM (x25519mlkem768) | **6,284** | 2,029 | 4,255 | 196 | 18 |
| Mixed chain + hybrid KEM | **23,924** | 2,900 | 21,024 | 263 | 42 |
| Pure PQC chain + hybrid KEM | **27,095** | 2,071 | 25,024 | 260 | 42 |

## What the deltas mean

Three transitions, three different cost structures. Each one corresponds to a different architectural decision an OEM has to make on a different timeline.

| Transition | Δ Total bytes | Δ TCP segments | Architectural meaning |
|---|---:|---:|---|
| Classical → Hybrid KEM | **+2,361 B** | +2 | The cost of HNDL defense. Bandwidth-only — no cert lifecycle change, no PKI migration. Deployable today. |
| Hybrid KEM → PQ trust anchor | **+17,640 B** | +24 | The cost of PQ-protecting root + sub-CA certificates. Decadal cost — root certs rotate on 20-40 year timelines. |
| PQ trust anchor → PQ leaf | **+3,171 B** | 0 | The cost of PQ-protecting the leaf certificate and its CertificateVerify signature. Paid per handshake. |

**Three observations from the data:**

1. **The hybrid KEM is essentially free.** 2.4 KB per handshake to defeat harvest-now-decrypt-later is a rounding error on any realistic SDV cloud connection. There is no defensible reason for any production SDV cloud backend to not deploy hybrid PQC KEM in 2026.

2. **The trust anchor is the expensive layer.** PQ-protecting the root and sub-CA adds 18 KB and doubles TCP segments. The fragmentation matters more than the bytes — each PQC handshake crosses two TCP MTUs instead of one, adding wire round-trips on any path with non-trivial latency.

3. **The leaf upgrade is incremental.** Once the PKI is already PQ-protected at the anchor, swapping the leaf to ML-DSA adds only 3 KB. This means OEMs can deploy `mixed` chains in 2027–2030 and `pqc` chains later without re-architecting anything.

## Threat coverage by configuration

Legend: 🟢 protected · 🟡 partial / depends on configuration · 🔴 broken

| # | Attack class | Classic | Hybrid (KEM-only) | Pure PQC |
|---|---|:---:|:---:|:---:|
| 1 | Classical passive eavesdropper, decrypt today | 🟢 | 🟢 | 🟢 |
| 2 | Classical active MITM, today (forge signature) | 🟢 | 🟢 | 🟢 |
| 3 | Classical active downgrade (force weaker group) | 🟡 | 🟡 | 🟢 |
| 4 | Harvest-now-decrypt-later — Q-day adversary | 🔴 | 🟢 | 🟢 |
| 5 | Q-day forgery against a recorded handshake | 🔴 | 🔴 | 🟢 |
| 6 | Q-day live forgery against today's certificate chain | 🔴 | 🔴 | 🟢 |
| 7 | Q-day forgery against archived chain | 🔴 | 🔴 | 🟢 |
| 8 | Side-channel on classical primitive (well-studied) | 🟢 | 🟢 | 🟡 |
| 9 | Side-channel on PQC primitive (less-studied) | 🟢 | 🟡 | 🟡 |
| 10 | Implementation bug in PQC library (newer code) | 🟢 | 🟡 | 🟡 |

## Reading the table

**Rows 1-2 — classical adversary, today.** All three modes resist a present-day attacker. X25519 is unbroken against classical compute, ECDSA cert chains are unforgeable to a non-quantum attacker. The baseline holds.

**Row 3 — classical downgrade.** A man-in-the-middle who can rewrite extensions tries to force the connection onto a weaker algorithm. TLS 1.3's transcript hash defends against this, but only if both sides actually require PQ. A hybrid configuration that falls back to classical-only on negotiation failure is exposed. Pure PQC mode that refuses anything classical is safest.

**Row 4 — HNDL, the headline.** An attacker records traffic today, waits for a cryptographically relevant quantum computer, runs Shor's algorithm against the recorded X25519 key share, derives the session key, decrypts the AES-GCM application data. Classical mode is fully exposed. Hybrid and pure PQC defeat it because the shared secret is `HKDF(ss_ec || ss_pq)` and ss_pq survives quantum. This is *the* row that motivates PQC migration.

**Rows 5-7 — Q-day signature forgery.** A future quantum attacker with Shor's algorithm can forge ECDSA signatures retroactively, in real time, or against archived PKI material. Anything still relying on ECDSA at the certificate level loses authentication when CRQC arrives. Only pure PQC (ML-DSA throughout the chain) defends. Row 7 is the V2G PKI case — a Root certificate designed for a 30-year lifespan must use a PQ signature today to survive Q-day.

**Rows 8-10 — implementation maturity.** The reverse exposure: classical primitives have 20+ years of constant-time implementation hardening; PQC primitives are newer. A side-channel attack against ML-KEM or ML-DSA is plausible in 2026 in a way it isn't against X25519. The hybrid construction is *more robust* to this than pure PQC: if a PQC implementation flaw leaks ss_pq, the classical ss_ec still protects the session. This is why hybrid is recommended as the transition posture rather than pure PQC.

## The contrarian take

In 2026, **pure PQC is paradoxically more risky than hybrid** despite being "more post-quantum." If a lattice cryptanalytic break or implementation flaw in ML-KEM or ML-DSA is discovered in the next 2-5 years — not impossible, the algorithms are recent and signature schemes historically take time to harden — a pure PQC deployment loses both its key exchange and its authentication at once. A hybrid deployment loses only the PQC contribution; the classical X25519 still protects against today's adversary while the patch ships.

NIST and BSI both recommend hybrid as the *transition posture*. Pure PQC is for the late 2030s, after the algorithms have seen years of deployment at scale. **Hybrid isn't compromise — it's load-bearing prudence.**

## The migration path the table reveals

Stop treating PQC migration as one binary decision. It's three independent decisions on three different timelines:

1. **Hybrid KEM, today (2026):** 2.4 KB cost, defeats HNDL, requires only a TLS library upgrade. No cert lifecycle change. Should be the default for every new SDV cloud deployment going live in 2026.

2. **PQ trust anchor, 2027-2030:** 18 KB cost, defeats Q-day forgery against the long-lived V2G Root. Requires a CA hierarchy migration — slow, decadal, deliberate. Coordinate with the V2G Root Operator's PKI roadmap.

3. **PQ leaves, 2030+:** 3 KB cost, completes the PQ transition. Requires the issuance toolchain (provisioning certs, contract certs, ISO 15118-20 PnC) to support ML-DSA leaves. Lowest priority because leaves rotate quickly and the practical attack window (Q-day live forgery against a still-valid leaf) is narrow.

The cost of each migration is now measured, not speculative. The architectural decisions that follow are about timing and operational risk, not about whether the math works.
