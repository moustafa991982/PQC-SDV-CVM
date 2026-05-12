# Architecture

The system has two physical locations and one logical chain of trust spanning them.

![Architecture overview](../assets/architecture.png)

## Physical layout

### Laptop side (developer workstation)

The laptop is the operator's machine and also hosts the simulated **vehicle communication unit (VCU)**. Concretely:

- **Azure CLI orchestrator** — bash scripts that talk to ARM via `az`, manage state in `scripts/.state`, and provision/teardown the Azure side.
- **OpenSSL 3.5 + oqs-provider** — used locally to generate the three certificate chains. OpenSSL 3.5 has native ML-KEM and ML-DSA in its default provider; `oqs-provider` is a fallback only needed if you're stuck on OpenSSL 3.4 or earlier.
- **QEMU "VCU" virtual machine** — Ubuntu 24.04 amd64 cloud image, KVM-accelerated, isolated network namespace. This is what makes a TLS handshake against the Azure CVM and is what `tshark` captures from. Hosts another OpenSSL 3.5 build.
- **Measurement harness** — Make targets that SSH into the QEMU VCU, start a tshark capture, run N back-to-back handshakes, scp the pcap back, and parse it into JSON metrics.

The VCU is on the same physical machine as the orchestrator, but cryptographically and operationally separated — the orchestrator never sees the VCU's filesystem, and the VCU's network egress goes through QEMU's user-mode NAT to the public internet, not through a privileged host pathway. This matters for measurement honesty: the handshake we measure traverses the same internet path a real vehicle's connectivity ECU would.

### Azure side (West Europe region)

All Azure resources live in a single resource group (`rg-pqc-sdv-demo` by default). The cast of characters:

- **Confidential VM** — `Standard_DC2as_v5`, AMD SEV-class memory encryption. Boots Ubuntu 22.04 from the canonical confidential VM image. Has a system-assigned managed identity. The CVM is the only piece in Azure that handles plaintext private key material.
- **nginx + OpenSSL 3.5** — runs inside the CVM. Built from source against OpenSSL 3.5. Serves TLS 1.3 with `ssl_conf_command Groups X25519MLKEM768:x25519:secp256r1`. Switches between three certificate chains via symlinks under `/etc/pqc-sdv/active/`.
- **Microsoft Azure Attestation (MAA)** — verifies a SEV-SNP report and returns a signed JWT. Used (architecturally) by the CVM to prove its identity to Key Vault during Secure Key Release.
- **Azure Key Vault Premium** — holds three SKR-gated **wrap keys** (one per chain) and three **secrets** containing the leaf private keys. The wrap keys carry release policies bound to the MAA provider. The CVM's managed identity has `Key Vault Crypto Service Release User` (to invoke `release`) and `Key Vault Secrets User` (to fetch the secrets).
- **Azure Blob Storage** — holds the three cert chains. Each chain lives at `certs/<chain-name>/{fullchain.pem, leaf.crt, chain.pem}`. The CVM's managed identity has `Storage Blob Data Reader` on this storage account. See [LIMITATIONS.md](LIMITATIONS.md) for why cert chains aren't in Key Vault.
- **NSG, vNet, public IP** — minimal networking, port 443 (HTTPS) and port 22 (SSH) only, both source-restricted to the laptop's public IP.

## The two operational phases

### Phase 1 — chain switch (a few seconds, runs when you change chains)

When the operator runs `./scripts/04_start_nginx.sh <chain>`:

1. The orchestrator SSHes into the CVM and runs `/usr/local/bin/nginx-switch.sh <chain>`
2. The switch script invokes `fetch-skr-key.py <chain>` which:
   - Authenticates to Azure as the CVM's managed identity
   - Calls Key Vault's `release_key(wrap-key-<chain>, attestation_jwt)` (architecturally — see Limitations)
   - Calls Key Vault's `get_secret(leafkey-<chain>-pem)` and writes it to `/etc/pqc-sdv/keys/<chain>.key`
   - Calls Blob Storage's `download_blob(certs/<chain>/fullchain.pem)` and writes it to `/etc/pqc-sdv/certs/<chain>.fullchain.pem`
3. The switch script swaps `/etc/pqc-sdv/active/{key,fullchain}.pem` symlinks
4. nginx is started (or reloaded if already running) against the updated paths

Switch time: typically 3–5 seconds. The CVM does not generate new keys per switch — it materializes pre-provisioned keys held in Key Vault, which is how a production deployment would work (key generation is a separate lifecycle event).

### Phase 2 — per-connection (every TLS handshake)

When the QEMU VCU initiates a TLS 1.3 connection:

1. **ClientHello** carries a `key_share` extension with concatenated X25519 (32 bytes) and ML-KEM-768 (1184 bytes) public keys. The `supported_groups` extension lists `X25519MLKEM768` and (optionally) classical fallbacks.
2. **ServerHello** returns the server's X25519 share (32 bytes) and the ML-KEM ciphertext (1088 bytes) in a corresponding `key_share`. nginx is using OpenSSL 3.5's native ML-KEM implementation here.
3. Both sides derive the **handshake secret** as `HKDF-Extract(salt, ss_ec || ss_pq)` — concatenation of the X25519 and ML-KEM shared secrets, fed through HKDF. The handshake is unbroken if either primitive holds.
4. **Certificate** and **CertificateVerify** flow encrypted under the handshake-traffic key. The leaf cert is whichever chain is currently symlinked active; the signature in CertificateVerify is ECDSA or ML-DSA depending on the leaf's algorithm.
5. **Finished** messages confirm transcript integrity, **application data** flows under AES-256-GCM derived from the handshake secret.

See [HANDSHAKE.md](HANDSHAKE.md) for the byte-by-byte walkthrough.

## Three certificate chains, one PKI structure

To keep the comparison apples-to-apples, all three chains share:

- The same three-tier hierarchy (root → sub-CA → leaf)
- The same SubjectAltName (`vcu-backend.local`)
- The same Extended Key Usage (`serverAuth`)
- The same validity intervals (root 10 years, sub-CA 5 years, leaf 1 year)

Only the **algorithms** differ:

| Chain | Root | Sub-CA | Leaf |
|---|---|---|---|
| `classical` | ECDSA-P256 | ECDSA-P256 | ECDSA-P256 |
| `mixed` | ML-DSA-87 | ML-DSA-65 | ECDSA-P256 |
| `pqc` | ML-DSA-87 | ML-DSA-65 | ML-DSA-44 |

The "mixed" pattern (PQC at root and sub-CA, classical at leaf) is the realistic 2027–2030 deployment shape for a V2G PKI:

- The V2G Root is intended to live 30–40 years → must be quantum-safe at the *root*
- Provisioning certificates are long-lived → benefit from PQC sub-CA
- Contract certificates and end-entity leaves are short-lived (months) → can defer PQC migration until the leaf-issuance toolchain is ready

This asymmetry is why mixed chains are the most under-discussed and most operationally relevant migration topology.

## State management

State that survives between script invocations:

- `scripts/.state` — written by `01_provision_azure.sh`, read by every subsequent script. Contains resource names, public IP, MAA URI, KV URI, blob URL, and managed identity principal ID. **Not committed to git.**
- `scripts/.known_hosts` — project-local SSH known-hosts file so the demo doesn't pollute `~/.ssh/known_hosts` when the CVM is recreated.
- `certs/out/<chain>/` — the locally-generated cert chains. Regeneration is idempotent.

State that lives in Azure (and is read by the CVM at runtime):

- Key Vault secrets: `leafkey-{classical,mixed,pqc}-pem`
- Key Vault keys (RSA-HSM wrap keys with SKR policies): `wrapkey-{classical,mixed,pqc}`
- Blob Storage blobs: `certs/{classical,mixed,pqc}/{fullchain.pem, leaf.crt, chain.pem}`

The CVM holds no persistent state — every chain switch re-fetches from Azure. This is by design: rebuilding the CVM should never lose security material, and the threat model assumes the CVM disk is not trusted (it's the encrypted-RAM that is).

## Observations on the architecture

A few things this design surfaced that aren't obvious from the standards:

**Key Vault for *keys*, blob for *artifacts*.** The clean separation of "secret material" (private keys) from "public artifact" (cert chains) maps naturally onto two different Azure primitives. Both are accessed via the same managed identity; the threat model is unchanged. This split also sidesteps Key Vault's 25.6 KB secret limit, which ML-DSA cert chains exceed.

**The CVM is the only plaintext zone.** Cert chains in blob are public. Wrap keys in Key Vault are released only inside the CVM. Leaf private keys exist in plaintext only inside the CVM's encrypted RAM. The boundary is a single VM, well-defined, easy to reason about.

**Switching chains is cheap.** No re-provisioning, no re-issuing certs, no nginx restart from scratch — just `release` + `get_secret` + `download_blob` + symlink swap + `nginx -s reload`. ~3 seconds. This is what makes the measurement harness practical.

**Attestation is architectural, runtime is RBAC.** As of mid-2026, the Azure Ubuntu 22.04 CVM image does not expose `/dev/sev-guest` for guest-initiated SEV-SNP attestation. The SKR policies on the wrap keys still exist and are bound to MAA — the *infrastructure* is correct for the production attestation flow. The runtime path in this demo uses managed-identity RBAC. When the kernel/image alignment ships, the same Key Vault wrap keys will gate access via attestation without any architectural change. See [LIMITATIONS.md](LIMITATIONS.md).
