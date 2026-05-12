# pqc-sdv-cvm

**Post-quantum TLS to a Software Defined Vehicle (SDV) cloud backend** — running inside an Azure SEV-SNP confidential VM, with private keys held in Azure Key Vault under Secure Key Release (SKR) policies and cert chains served from Azure Blob Storage. The client is a QEMU virtual ECU on the operator's laptop. The whole stack uses OpenSSL 3.5 with native ML-KEM and ML-DSA.

The goal is to measure — on real Azure infrastructure, over a real WAN — what it actually costs to make a SDV cloud backend quantum-safe today, broken down by which part of the system you're hardening.

![Architecture](assets/architecture.png)

## What this demo measures

Three certificate chains × two KEM choices, end-to-end against a real Azure CVM:

| Chain | Root | Sub-CA | Leaf | TLS KEM | What it represents |
|---|---|---|---|---|---|
| **classical** | ECDSA-P521 | ECDSA-P384 | ECDSA-P256 | X25519 | today |
| **classical** | ECDSA-P521 | ECDSA-P384 | ECDSA-P256 | **X25519MLKEM768** | the 2026 transition |
| **mixed** | ML-DSA-87 | ML-DSA-65 | ECDSA-P256 | X25519MLKEM768 | PQ trust anchor, classical leaf |
| **pqc** | ML-DSA-87 | ML-DSA-65 | ML-DSA-44 | X25519MLKEM768 | the 2030+ end state |

For each row we capture 20 TLS 1.3 handshakes inside the simulated VCU, parse the pcap, and report median bytes, latency, and TCP segments.

![Measured results](assets/results-example.png)

**The three deltas tell the migration story:**

- Adding the **hybrid PQC KEM** to a classical handshake costs **~2.4 KB per handshake**. That defeats harvest-now-decrypt-later. There is no reason not to deploy this today.
- Adding **PQ signatures to the trust anchor** (root + sub-CA) costs **~18 KB on top**. That's the cost of decadal PKI migration — pay it on V2G PKI timelines, not next quarter.
- Adding **PQ signatures to the leaf** is a further **~3 KB**. Smallest jump, but it pays per-handshake.
- The interesting effect: at the PQ-PKI boundary, **TCP segments jump from 18 to 42**. PQC handshakes don't just get bigger — they fragment, adding wire round-trips on a real WAN.

## Architecture in one paragraph

The Azure CVM boots on `Standard_DC2as_v5` (AMD SEV-SNP), Ubuntu 22.04, with a system-assigned managed identity. nginx + OpenSSL 3.5 serve TLS 1.3 on port 443. When the operator switches chains, the CVM's `fetch-skr-key.py` authenticates to Azure as the managed identity, asks Key Vault to release a chain-specific wrap key (architecturally, after SEV-SNP attestation via MAA — see [Path 3 limitation](docs/LIMITATIONS.md)), fetches the leaf's private key as a Key Vault secret, downloads the PEM cert chain from Blob Storage (because the ML-DSA chains exceed Key Vault's 25 KB secret limit), then atomically swaps nginx's symlinks. The QEMU VCU on the laptop runs an OpenSSL 3.5 client through QEMU's user-mode NAT to the public internet, hits the CVM, and tshark captures the handshake.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the long version with every component and trust boundary.

## Quick start

This requires an Azure subscription with confidential-computing quota in West Europe, a Linux laptop with KVM, and patience for one-time provisioning.

```bash
# 1. Install prereqs (az CLI, OpenSSL 3.5, QEMU + KVM, tshark, etc.)
./scripts/00_prereqs.sh

# 2. Log in to Azure, register resource providers, set a short demo prefix
az login
export DEMO_PREFIX="pqcdemo$(date +%s | tail -c 4)"

# 3. Provision Azure: RG, CVM, Key Vault, MAA, Storage, NSG (~5 minutes)
./scripts/01_provision_azure.sh

# 4. Build the 3 cert chains + import keys to KV + upload chain PEMs to Blob
./scripts/02_import_keys_and_blobs.sh

# 5. Bootstrap the CVM: install nginx, build OpenSSL 3.5, deploy fetch-skr-key.py
./scripts/03_bootstrap_cvm.sh

# 6. Start nginx serving a chain (classical | mixed | pqc)
./scripts/04_start_nginx.sh classical

# 7. Boot the QEMU VCU (separate terminal - first run takes ~10 minutes for cloud-init)
( cd qemu-client && make run-vm )

# 8. Run the four measurement scenarios
cd measure
make scenario CHAIN=classical KEM=x25519
make scenario CHAIN=classical KEM=x25519mlkem768
( cd .. && ./scripts/04_start_nginx.sh mixed )
make scenario CHAIN=mixed KEM=x25519mlkem768
( cd .. && ./scripts/04_start_nginx.sh pqc )
make scenario CHAIN=pqc KEM=x25519mlkem768

# 9. Produce the chart + table
make report

# 10. Tear down all Azure resources (CRITICAL — CVM costs ~$0.30/hr)
cd .. && ./scripts/99_teardown.sh
```

For the full step-by-step with what to expect at each stage, see [docs/INSTALL.md](docs/INSTALL.md).

## Documentation

| File | Purpose |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | Full installation guide with troubleshooting |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | What every component does and how they connect |
| [docs/HANDSHAKE.md](docs/HANDSHAKE.md) | Byte-level walkthrough of the TLS 1.3 hybrid PQC handshake |
| [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) | What each cryptographic layer defends against, and what it doesn't |
| [docs/LIMITATIONS.md](docs/LIMITATIONS.md) | Honest catalogue of every shortcut, workaround, and not-yet-implemented thing |

## What this demo is not

This is a **measurement and learning tool**, not a production reference architecture. Specifically:

- **Live SEV-SNP attestation is not invoked** in the runtime path. The Ubuntu 22.04 confidential-VM kernel image (`6.8.0-1053-azure-fde`) does not expose `/dev/sev-guest` to the guest. The architecture preserves SKR wrap keys with MAA-bound release policies in Key Vault, but runtime authorization uses managed-identity RBAC (Path 3). The platform-level CVM boundary (AMD memory encryption) is real and verified via `dmesg`. See [docs/LIMITATIONS.md](docs/LIMITATIONS.md#1-live-sev-snp-attestation-is-skipped-in-runtime-path-path-3).
- **Demo-grade PKI** — self-signed roots, never chained to public trust stores; OpenSSL `-CAfile` for client trust; no CRL/OCSP/CT.
- **No HSM-backed CA** — root and sub-CA private keys live on the laptop's filesystem during chain build.
- **Cert chains over Blob, not Key Vault** — ML-DSA fullchains exceed Key Vault's 25 KB secret limit. Blob Storage is the practical answer in 2026; future Azure Key Vault Managed HSM removes this constraint for certificates.
- **No client-side attestation** of the QEMU VCU — the demo is one-way TLS, not mTLS. mTLS with V2G PKI client certs is left as an exercise.

## Acknowledgements

This work was built around publicly available NIST PQC specifications (FIPS 203 ML-KEM, FIPS 204 ML-DSA), OpenSSL 3.5's native PQC support, Azure Confidential Computing SEV-SNP CVMs, and the [draft-ietf-tls-hybrid-design](https://datatracker.ietf.org/doc/draft-ietf-tls-hybrid-design/) hybrid KEM construction. References are listed in [docs/HANDSHAKE.md](docs/HANDSHAKE.md).

## License

MIT — see [LICENSE](LICENSE).

## Contact

Moustafa El Bahaey — Chief Systems Engineer / Cybersecurity Manager, EVRaid
[github.com/moustafa991982](https://github.com/moustafa991982)
