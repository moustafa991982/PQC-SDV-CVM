# The TLS 1.3 hybrid PQC handshake, byte by byte

This document unpacks what a `X25519MLKEM768` handshake actually does on the wire, why it's "hybrid," and what makes it resistant to harvest-now-decrypt-later.

![Handshake sequence](../assets/handshake-sequence.png)

## What "hybrid" means in TLS 1.3

TLS 1.3 separates two concerns that older TLS versions conflated:

1. **Key exchange** — establishing a shared secret over an authenticated channel
2. **Authentication** — proving server identity via certificate signatures

In TLS 1.2, both used the same algorithm family (RSA, or ECDHE+RSA, or ECDHE+ECDSA). In TLS 1.3, the two are independent: you can pick any named group for key exchange and any signature algorithm for authentication, and they negotiate separately.

**Hybrid PQC** refers specifically to the *key exchange* — using **two** key exchange primitives in parallel and combining their outputs, so the channel is secure if **either** primitive is unbroken. The signature side is independent: you can use hybrid PQC KEM with classical ECDSA certs, or with pure PQ ML-DSA certs, or anything in between.

This is the "channel is PQ but cert isn't" property the `classical + x25519mlkem768` scenario demonstrates.

## The standard: X25519MLKEM768

- **IETF draft**: `draft-kwiatkowski-tls-ecdhe-mlkem`
- **IANA codepoint**: `0x11EC` for the `X25519MLKEM768` named group
- **Construction**: concatenate the X25519 shared secret with the ML-KEM-768 shared secret, feed into HKDF-Extract
- **Status**: shipped in OpenSSL 3.5 (April 2025), Chrome 124+, BoringSSL, Cloudflare, AWS, Apple platforms

The "768" refers to the ML-KEM-768 parameter set (NIST security category 3, roughly equivalent to AES-192 against classical attacks and Grover-bounded against quantum).

## What the wire looks like

### 1. Client generates ephemerals

Before sending anything, the TLS client generates **two independent keypairs**:

- **X25519**: a random 32-byte scalar `x` (the private key), and the corresponding public point `X = x · G` on Curve25519. The public key is 32 bytes. The math is standard elliptic-curve Diffie-Hellman.
- **ML-KEM-768**: a 2,400-byte private key derived from a 64-byte random seed, and a 1,184-byte public key. The internal math is Module-LWE over polynomial rings — a lattice problem with no known efficient quantum algorithm.

Both keypairs are *ephemeral*: they live only for this one handshake and are wiped after the session keys are derived. Forward secrecy depends on this.

### 2. ClientHello

The client sends a TLS 1.3 ClientHello including a `key_share` extension. The `key_share` for the `X25519MLKEM768` group is the concatenation of the two public keys:

```
key_exchange = X25519_public_key (32 bytes) || ML-KEM-768_public_key (1184 bytes)
```

Total: 1,216 bytes for the `key_share` payload alone, vs. 32 bytes for X25519 alone. Plus extension framing and other ClientHello content, the full ClientHello is around 1.3–1.5 KB. **This is the first place hybrid PQC costs bandwidth.**

### 3. Server processes ClientHello

When nginx (with OpenSSL 3.5) receives the ClientHello, it performs two independent operations:

**X25519 side**: the server generates its own random scalar `y`, computes `Y = y · G`, and computes the shared point `S_ec = y · X = (xy) · G`. The 32 bytes of `S_ec` become `ss_ec`, the classical shared secret.

**ML-KEM side**: the server runs `(ct, ss_pq) = ML-KEM-768.Encapsulate(client_pk)`. This is the "KEM" part — Key Encapsulation Mechanism:

- The server picks a random message `m` internally
- Encrypts `m` under the client's ML-KEM public key, producing a 1,088-byte ciphertext `ct`
- Hashes `m` to produce a 32-byte shared secret `ss_pq`

The server now holds `ss_pq` (32 bytes) and `ct` (1,088 bytes). The client, holding the private key, will recover the same `ss_pq` from `ct` via decapsulation.

### 4. ServerHello

The server sends a ServerHello with a corresponding `key_share`:

```
key_exchange = X25519_server_public (32 bytes) || ML-KEM_ciphertext (1088 bytes)
```

Total: 1,120 bytes. The second of the two big PQC-specific payloads on the wire.

### 5. Client processes ServerHello

Mirror image of the server side:

**X25519**: `S_ec = x · Y` — the client's private scalar times the server's public point. Mathematically equal to `y · X` from the server side. Same 32-byte `ss_ec`.

**ML-KEM**: `ss_pq = ML-KEM-768.Decapsulate(client_sk, ct)` — the client uses its ML-KEM private key to recover `m` from `ct`, then hashes it the same way the server did. Same 32-byte `ss_pq`.

Both sides now hold `(ss_ec, ss_pq)`. Each is 32 bytes. **They were derived through two completely independent mechanisms.**

### 6. Combine into the handshake secret

This is the cryptographic core of the hybrid construction. Per the IETF draft, both sides compute:

```
shared_secret = ss_ec || ss_pq          # 64 bytes total, concatenated
handshake_secret = HKDF-Extract(salt = derived_secret, IKM = shared_secret)
```

There is no XOR, no addition, no exotic blending. The two shared secrets are simply concatenated and fed into TLS 1.3's standard HKDF extraction. This is **deliberately conservative** — it means the handshake secret is at least as strong as the *stronger* of the two underlying secrets.

The formal security argument: HKDF-Extract with a uniformly random salt is a pseudorandom function. If either `ss_ec` *or* `ss_pq` is computationally indistinguishable from random, then their concatenation is too, and `HKDF-Extract` produces a uniformly random output unknowable to the attacker. So:

- **If quantum computers don't materialize** → `ss_ec` is secure (ECDLP is hard) → handshake secret is secure.
- **If quantum computers do materialize** → `ss_pq` is secure (M-LWE is hard for quantum too) → handshake secret is secure.

**The hybrid handshake is unbroken if at least one of the two primitives is unbroken.** This is the central security property and the entire reason for paying the bandwidth cost.

### 7–9. Encrypted server messages

From the handshake secret, TLS 1.3 derives `client_handshake_traffic_secret` and `server_handshake_traffic_secret` via `HKDF-Expand-Label`. Everything from here forward is encrypted under these keys.

The server sends, all under encryption:

- **EncryptedExtensions** (small, application-layer metadata)
- **Certificate** (the leaf cert + sub-CA, plus optionally the root). For the `classical` chain this is ~3 KB; for the `pqc` chain it's ~26 KB.
- **CertificateVerify** — a signature over the transcript hash using the leaf private key. For ECDSA-P256 this is ~70 bytes; for ML-DSA-44 this is ~2,420 bytes.
- **Finished** — HMAC of the transcript using a derived key, proving the server has the right handshake secret.

### 10. Client Finished

The client verifies the certificate chain, verifies the CertificateVerify signature against the leaf's public key, and verifies the server Finished. If all three pass, it sends its own Finished. The 1-RTT TLS 1.3 handshake is complete.

### 11. Application data

From the handshake secret, TLS 1.3 derives the application traffic keys:

```
master_secret = HKDF-Extract(derived(handshake_secret), 0)
client_application_traffic_secret_0 = HKDF-Expand-Label(master_secret, "c ap traffic", ...)
server_application_traffic_secret_0 = HKDF-Expand-Label(master_secret, "s ap traffic", ...)
```

These derive AES-256-GCM keys + IVs for the actual HTTPS data. **Every byte from here is downstream of the hybrid `ss_ec || ss_pq`** — the PQC protection propagates to all application traffic, not just the handshake.

## What the hybrid construction defends against

The headline threat is **harvest-now-decrypt-later (HNDL)**: an adversary records traffic today, stores it, waits for a cryptographically relevant quantum computer (CRQC), then breaks it retroactively. Against a CRQC-equipped attacker who has recorded one of our handshakes:

1. They can run Shor's algorithm against `Y` (the server's X25519 public share) to recover `y`, and then compute `ss_ec`. ✅ X25519 broken.
2. They **cannot** recover `ss_pq` from `ct` without breaking ML-KEM (which they can't). ❌ ML-KEM holds.
3. They therefore **cannot reconstruct** `HKDF-Extract(ss_ec || ss_pq)`. ❌ Handshake secret holds.
4. They **cannot derive** the AES-GCM keys → **cannot decrypt** the application data.

The recorded session is permanently safe, even after Q-day.

This is why hybrid PQC KEM is the **single most important** PQC deployment to do today, ahead of PQ certificate migration. The threat model is asymmetric: ciphertexts can be archived (and *are* — there is open evidence of state actors doing this), but signatures from old handshakes are not retroactively useful to an attacker. So channel-confidentiality is the urgent problem; signature migration is the slower decadal one.

## What hybrid PQC does *not* defend against

For completeness:

- **Active MITM today** — defeated by the cert chain (whatever signature algorithm it uses). Hybrid KEM doesn't help here. The classical CA chain handles it for classical adversaries.
- **Q-day live forgery against ECDSA-signed certs** — a CRQC-equipped attacker can break ECDSA signatures live and impersonate the server. The `mixed` and `pqc` chains address this by using ML-DSA at the trust anchor and (in `pqc`) at the leaf. Hybrid KEM alone doesn't help.
- **Implementation bugs** — a flaw in OpenSSL's ML-KEM implementation could compromise `ss_pq`, but the classical `ss_ec` still protects the session. This is the *other* benefit of hybrid: it's defense-in-depth against PQC implementation immaturity.

## Why this matters for SDV

Most automotive PQ discussion focuses on PKI: "When do we move V2G certs to ML-DSA?" That's a decadal question.

Hybrid KEM is a **deployment** question, not a PKI question. A KEM swap is one TLS library upgrade plus one server config change. No certificate lifecycle, no PKI migration, no V2G Root Operator coordination, no fleet rollout.

**The realistic 2026 deployment posture for any SDV cloud backend is hybrid KEM with classical certs.** That defeats HNDL today, at ~2.4 KB/handshake. The PKI migration to PQ-signed roots and intermediates is a separate, slower project. The two can — and should — proceed independently.
