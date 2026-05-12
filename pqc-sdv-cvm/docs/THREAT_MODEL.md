# Threat model: classical vs hybrid vs pure PQC

The three certificate chains in this demo correspond to three distinct deployment postures with distinct security properties. This document is a row-by-row attack comparison.

## Mode definitions

For an SDV cloud backend running TLS 1.3, "deployment mode" decomposes into two independent axes:

| Mode | Key exchange | Leaf certificate signature |
|---|---|---|
| **Classic** | X25519 alone | ECDSA-P256 |
| **Hybrid** | X25519 + ML-KEM-768 | ECDSA-P256 (or mixed) |
| **Pure PQC** | X25519 + ML-KEM-768 | ML-DSA-44 |

The demo's chains map to these as:
- `classical` chain + `x25519` KEM = **Classic**
- `classical` chain + `x25519mlkem768` KEM = **Hybrid** (with classical certs)
- `mixed` chain + `x25519mlkem768` KEM = **Hybrid** with PQ-protected trust anchor (the realistic 2027–2030 deployment)
- `pqc` chain + `x25519mlkem768` KEM = **Pure PQC**

## Attack comparison

Legend: 🟢 protected | 🟡 partial / depends on configuration | 🔴 broken

| # | Attack | Classic | Hybrid (KEM only) | Pure PQC |
|---|---|---|---|---|
| 1 | Classical passive eavesdropper, decrypt today | 🟢 | 🟢 | 🟢 |
| 2 | Classical active MITM, today (forge sig) | 🟢 | 🟢 | 🟢 |
| 3 | Classical active downgrade (force weaker group) | 🟡 | 🟡 | 🟢 |
| 4 | Harvest-now-decrypt-later — Q-day adversary | 🔴 | 🟢 | 🟢 |
| 5 | Q-day forgery against a recorded handshake | 🔴 | 🔴 | 🟢 |
| 6 | Q-day live forgery against today's cert chain | 🔴 | 🔴 | 🟢 |
| 7 | Q-day forgery against archived chain | 🔴 | 🔴 | 🟢 |
| 8 | Classical side-channel on classical primitive | 🟢 | 🟢 | 🟡 |
| 9 | Classical side-channel on PQC primitive | 🟢 | 🟡 | 🟡 |
| 10 | Implementation bug in PQC library (newer code) | 🟢 | 🟡 | 🟡 |

## Row-by-row

**Row 1 — Classical passive eavesdropper today.** All three modes resist a non-quantum attacker recording and trying to break today. X25519 is unbroken classically; no quantum needed.

**Row 2 — Classical active MITM today.** Defeated by the CA chain in all three modes. ECDSA-P256 is computationally unforgeable to classical attackers, and even a Pure PQC adversary couldn't impersonate a classical CA without a CRQC.

**Row 3 — Classical downgrade.** An adversary who can rewrite the `supported_groups` extension may force a weaker named group than what both sides could support. TLS 1.3's transcript binding helps, but only if both sides actually require the strong group. Pure PQC mode is most resistant if the server is configured to refuse classical-only KEMs.

**Row 4 — Harvest-now-decrypt-later (the headline threat).** Adversary records traffic today, waits for a CRQC, runs Shor's algorithm against the X25519 share to recover the shared secret, then decrypts the AES-GCM application data. Classical mode is fully exposed. Hybrid and Pure PQC both block it: the hybrid handshake secret incorporates an ML-KEM contribution that Shor cannot break. **This is the threat that motivates immediate hybrid deployment.**

**Row 5 — Q-day forgery against a recorded handshake.** Subtle: can a CRQC attacker retroactively prove they were the server by forging the signature from a recorded handshake? No, because TLS 1.3 binds CertificateVerify to the ephemeral transcript hash — the signature is unforgeable *in context*, even if the leaf private key is later recovered. So Pure PQC's protection on this row is technically about reissuance to fake third parties, not retroactive forgery of recorded sessions.

**Row 6 — Q-day live forgery.** A CRQC-equipped attacker connects to clients pretending to be the legitimate server, in real time. They run Shor against the public ECDSA leaf or root key to derive the private key, then sign arbitrary messages. Classical and Hybrid mode (with ECDSA certs) are vulnerable. Pure PQC mode uses ML-DSA, which Shor cannot break. **This is the row that motivates moving certificates to PQ, not just KEMs.**

**Row 7 — Q-day forgery against archived chain.** Adversary uses a CRQC to forge signatures from long-expired private keys whose public keys remain in PKI archives, then attacks systems that trust historical chains for legacy compatibility. Most relevant for V2G PKI, where the V2G Root is designed to live 30+ years.

**Row 8 — Classical side-channel on classical primitive.** Timing attacks, EM emissions, fault attacks against X25519 or ECDSA. Twenty years of literature, mature constant-time implementations. Classic and Hybrid mode use these well-studied paths.

**Row 9 — Classical side-channel on PQC primitive.** Same logic for ML-KEM and ML-DSA. Hybrid mode uses ML-KEM in a constant-time-targeted implementation but the implementations are less battle-tested than X25519/ECDSA. Pure PQC uses both ML-KEM and ML-DSA; known side-channel concerns include rejection sampling timing and polynomial multiplication patterns.

**Row 10 — Implementation bugs.** Not really an "attack class" but operationally important. ML-KEM and ML-DSA implementations in 2026 have far less production exposure than ECDSA. **The hybrid construction provides defense in depth against PQ implementation bugs**: if a bug leaks `ss_pq`, the classical `ss_ec` still protects the session. Pure PQC has no such backstop — a single ML-KEM bug compromises the channel.

## The four key observations

**Classical mode is uniquely exposed** to the Q-day adversary recording today, but is the most battle-tested against today's adversaries.

**Hybrid mode is the only one that protects against both classical and quantum adversaries simultaneously** — at the cost of paying for both primitives in every handshake (~2.4 KB).

**Pure PQC mode is the only one that protects long-lived signatures**, but exposes operational risk in newer code with no classical fallback.

**The migration sequence the table reveals is:**
1. Hybrid KEM first (defeats HNDL with the lowest deployment risk because classical primitive backstops PQC bugs)
2. PQC at the trust anchor (defeats Q-day root forgery for long-lived CAs)
3. PQC at leaves (defeats Q-day live forgery — lowest priority because leaves are short-lived anyway)

## Why hybrid beats pure PQC for a 2026 deployment

A subtlety worth pulling out: **Pure PQC is paradoxically *more risky* than Hybrid in 2026, despite being "more post-quantum."**

If a lattice cryptanalytic break or implementation flaw in ML-KEM or ML-DSA is discovered in 2027 — not impossible, the algorithms are recent — a Pure PQC TLS deployment loses both its key exchange and its authentication at once. A Hybrid deployment loses only the PQ contribution; the classical X25519 still protects the channel against today's actual adversary while the team patches.

This is why NIST and BSI both recommend **hybrid as the *transition* posture** and reserve pure-PQC for after the algorithms have been deployed at scale and survived several years of adversarial scrutiny. Hybrid isn't compromise — it's load-bearing prudence.

## What the demo's CVM + SKR layer adds

The threat model above is about the TLS *protocol* security. The demo's architecture stacks one more mitigation on top:

**Server-side key confidentiality against a cloud insider.** Without the CVM, a Microsoft operator (or any party who compromised the hypervisor) could in principle read the server's TLS private key out of guest RAM. The CVM's SEV memory encryption prevents that — RAM is encrypted with a key only the AMD CPU knows.

This protects against a different adversary from the cryptographic threats above. It's an *architectural* mitigation, not a protocol mitigation. It applies equally to all three TLS modes — running classical TLS on a CVM is still better than running classical TLS on a regular VM, just as running PQC TLS on a CVM is still better than running PQC TLS on a regular VM.

The combined three-layer defense:

1. **Hybrid KEM** — defeats the future quantum adversary recording today's traffic
2. **ML-DSA at trust anchor** — defeats the future quantum adversary forging signatures
3. **CVM + SKR** — defeats the present-day cloud insider with hypervisor access

Each addresses a different adversary. The combination is what makes the architecture defensible for an SDV cloud backend in the 2027–2050 operational window.

## What this demo's threat model does *not* address

For complete transparency:

- **In-vehicle side**: the demo measures the cloud-backend half. In-vehicle attestation, AUTOSAR security, SecOC, HSM integration are out of scope here.
- **Lateral movement post-compromise**: if an attacker compromises the CVM via a software vuln, the CVM boundary is broken anyway.
- **Supply chain**: this demo doesn't reason about compromised Azure base images, compromised OpenSSL builds, or compromised AMD silicon.
- **Insider with subscription access**: someone with `Owner` on your Azure subscription can read the wrap keys' release policies, redeploy CVMs, etc. The CVM threat model is about *operators*, not subscription owners.
- **Side-channel attacks against the CVM itself**: SEV-SNP has known side-channel research (memory pattern observation, controlled-channel attacks). The demo treats the CVM as a clean boundary; that's a simplification.
