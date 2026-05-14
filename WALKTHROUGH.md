# Architecture walkthrough: every step, every file

This document walks through the [comprehensive architecture diagram](../assets/architecture-detailed.png) box-by-box, flow-by-flow, mapping each component to the exact file, script, or line that implements it. Read this as the bridge between "here's what the architecture looks like" and "here's where the code lives."

![Comprehensive cloud architecture](../assets/architecture-detailed.png)

The diagram is organized into five vertical regions:

1. **Laptop side** (purple) — operator workstation, outside the Azure trust boundary
2. **Identity & RBAC** (lavender) — Azure Entra ID + the CVM's managed identity
3. **Confidential VM** (dark blue) — the TEE boundary where plaintext keys live
4. **Attestation & key services** (red) — MAA + Key Vault Premium
5. **Storage & networking** (orange/teal) — Blob Storage + NSG/Public IP

Three flow types thread through the diagram:

- **Numbered arrows [1]–[6]** = the chain-switch sequence (key release, cert chain fetch)
- **Dashed gray line** = SSH provisioning and chain-switch triggers (laptop → CVM port 22)
- **Solid purple line** = the measured TLS handshake (QEMU VCU → CVM port 443)

Let's walk through each.

---

## 1. Laptop side

### 1.1 Operator + Azure CLI

**What it represents.** A human on a laptop in front of a terminal, with `az` (Azure CLI) installed and authenticated to an Azure subscription. Everything the demo provisions starts here.

**Files.**
- [`scripts/00_prereqs.sh`](../scripts/00_prereqs.sh) — installs `az`, OpenSSL 3.5, QEMU + KVM, `tshark`, `sshpass`, and the matching Python packages.
- [`scripts/env.sh`](../scripts/env.sh) — defines the default environment variables (`LOC=westeurope`, `RG=rg-pqc-sdv-demo`, etc.) that every subsequent script sources.

**Trust boundary.** The operator's laptop is *outside* the Azure trust boundary. The laptop has a bearer token from `az login` and can drive ARM, but it never sees plaintext leaf private keys or any data inside the CVM's encrypted memory. This is the key trust-model property the architecture preserves.

### 1.2 OpenSSL 3.5 (host)

**What it represents.** A from-source build of OpenSSL 3.5 living at `/usr/local/openssl/` on the laptop, used *only* to mint the three certificate chains locally before they're shipped to Azure. Distribution OpenSSL (3.0–3.3 on current Ubuntu) lacks native ML-KEM and ML-DSA support, so the demo builds 3.5 explicitly.

**Files.**
- [`scripts/00_prereqs.sh`](../scripts/00_prereqs.sh) — section "Build OpenSSL 3.5 from source"; verifies `openssl list -kem-algorithms | grep -i mlkem` succeeds.
- [`certs/build_chains.sh`](../certs/build_chains.sh) — uses this OpenSSL to generate all three chains under `certs/out/{classical,mixed,pqc}/`.
- [`certs/openssl.cnf.tmpl`](../certs/openssl.cnf.tmpl) — the CA configuration template (X.509 extensions, key usage, EKU, SAN).

**What it generates.** For each chain, a root CA, a sub-CA, and a leaf certificate with `CN=vcu-backend.example.com` and SAN `vcu-backend.local`. The algorithm varies per chain:

| Chain | Root | Sub-CA | Leaf |
|---|---|---|---|
| `classical` | ECDSA-P521 | ECDSA-P384 | ECDSA-P256 |
| `mixed` | ML-DSA-87 | ML-DSA-65 | ECDSA-P256 |
| `pqc` | ML-DSA-87 | ML-DSA-65 | ML-DSA-44 |

The leaf private keys are PEM-encoded for upload to Key Vault as secrets.

### 1.3 Provisioning scripts

**What it represents.** The bash scripts that drive Azure ARM via `az`, in the canonical order: `01 → 02 → 03 → 04 → 99`.

**Files.**
- [`scripts/01_provision_azure.sh`](../scripts/01_provision_azure.sh) — creates the resource group, vNet, NSG, Public IP, NIC, **CVM (with managed identity)**, MAA, Key Vault Premium, Storage account + container, and grants three RBAC role assignments to the CVM's managed identity.
- [`scripts/02_import_keys_and_blobs.sh`](../scripts/02_import_keys_and_blobs.sh) — runs `build_chains.sh`, then for each of the three chains uploads the leaf private key to Key Vault as a secret, creates the SKR-gated wrap key, and uploads the cert chain PEMs to Blob Storage.
- [`scripts/03_bootstrap_cvm.sh`](../scripts/03_bootstrap_cvm.sh) — SCPs `cvm-bootstrap.sh`, `fetch-skr-key.py`, `nginx/nginx.conf`, and `nginx-switch.sh` to the CVM, then SSHes in and runs the bootstrap.

### 1.4 `.state` (gitignored)

**What it represents.** A file at `scripts/.state` that captures the outputs of provisioning so subsequent scripts can find them: resource names, public IP, Key Vault URI, MAA URI, storage URL, managed identity principal ID.

**File.** [`scripts/01_provision_azure.sh`](../scripts/01_provision_azure.sh) — the section at the end that writes `cat > "${STATE_FILE}"`. Every other script begins with `source scripts/.state`.

**Why gitignored.** The state contains resource names, IPs, and IDs specific to your Azure subscription. The repo's `.gitignore` excludes `scripts/.state` so a `git commit` after a run doesn't leak them.

### 1.5 `04_start_nginx.sh <chain>`

**What it represents.** The operator-facing command to switch what cert chain the CVM is serving. Takes one of `classical`, `mixed`, or `pqc`.

**File.** [`scripts/04_start_nginx.sh`](../scripts/04_start_nginx.sh) — 18 lines, just SSHes into the CVM and runs `/usr/local/bin/nginx-switch.sh <chain>`. The heavy lifting happens inside the CVM in [`nginx/nginx-switch.sh`](../nginx/nginx-switch.sh).

This is the entry point for the numbered flow `[1]–[6]` in the diagram.

### 1.6 QEMU VCU

**What it represents.** A simulated vehicle communication unit running in a QEMU virtual machine on the laptop. Ubuntu 24.04 amd64, KVM-accelerated. Cloud-init installs OpenSSL 3.5 and tshark on first boot. The VCU is what makes the TLS handshakes that the demo measures.

**Files.**
- [`qemu-client/Makefile`](../qemu-client/Makefile) — `make run-vm` boots the VM with `qemu-system-x86_64 -enable-kvm -M q35 -cpu host` and port-forwards host port 12222 to guest port 22.
- [`qemu-client/user-data`](../qemu-client/user-data) — cloud-init config that creates the `vcu` user (password `vcu`, demo-grade), installs `tshark` + `dumpcap` with capabilities, builds OpenSSL 3.5 inside the guest via `/usr/local/bin/build-openssl.sh`.
- [`qemu-client/meta-data`](../qemu-client/meta-data) — minimal instance ID + hostname for cloud-init.

**Why it's a separate VM.** Three reasons: it isolates the measurement client from the operator's laptop tools (so a stray host openssl can't accidentally negotiate a different group), it makes the network path representative (egress goes through QEMU's user-mode NAT to the public internet, like a real vehicle's connectivity ECU would), and it makes tshark captures clean (only handshake traffic, no background noise from the operator's other apps).

### 1.7 Measurement harness

**What it represents.** The `make scenario` and `make report` targets that drive a measurement run.

**Files.**
- [`measure/Makefile`](../measure/Makefile) — the `scenario` target: SSHes into the VCU, starts tshark on `enp0s2` with a BPF filter `host <PIP> and port 443`, waits 3 seconds for the filter to install, runs N (20) back-to-back `openssl s_client` handshakes, kills tshark, SCPs the pcap back, parses with `parse_pcap.py` → `metrics.json`.
- [`measure/parse_pcap.py`](../measure/parse_pcap.py) — invokes `tshark -q -z conv,tcp`, parses byte counts (handling both `bytes` and `kB`/`MB` units), computes per-flow durations from first-packet-to-last-packet timestamps.
- [`measure/make_report.py`](../measure/make_report.py) — reads all `runs/*/metrics.json`, prints the markdown table.
- [`measure/make_chart.py`](../measure/make_chart.py) — reads the same, produces the 2×2 bar chart `results.png`.

### 1.8 Output artifacts

**What it represents.** The actual deliverables — what you take to LinkedIn or a conference.

**Files.**
- `measure/results.md` — markdown table of medians across the four scenarios.
- `measure/results.png` — the 4-panel chart (total bytes, S→C bytes, duration, segments).
- `measure/runs/*/hs.pcap` — the raw captures, kept for reproducibility.
- `measure/runs/*/hs.log` — the per-handshake openssl output (proof each one completed).
- `measure/runs/*/metrics.json` — the parsed numbers.

---

## 2. Identity & RBAC

### 2.1 Azure Entra ID (AAD)

**What it represents.** Microsoft's identity service, the issuer of bearer tokens for both the operator (via `az login`) and the CVM's managed identity (via IMDS).

**Where AAD enters the codebase.** AAD itself isn't a script — it's a service. Two places interact with it:

- **Operator authentication**: `az login` in the documented setup (see [`docs/INSTALL.md`](INSTALL.md) step 1). The resulting bearer token sits in `~/.azure/` and `az` reuses it for all subsequent operations.
- **CVM authentication**: [`scripts/fetch-skr-key.py`](../scripts/fetch-skr-key.py) line `cred = ManagedIdentityCredential()` — the Azure SDK uses the IMDS endpoint at `http://169.254.169.254/metadata/identity/oauth2/token` to fetch a token for the CVM's identity.

### 2.2 System-assigned managed identity

**What it represents.** A principal in Entra ID bound to the CVM's lifecycle. Lives as long as the CVM does, dies when the CVM is deleted. The CVM gets a token via the IMDS endpoint without any client secret, key file, or other static credential on disk — Azure verifies the request comes from the CVM's network interface and returns a token. This is what makes the CVM key-fetch architecturally clean: no secret rotation, no leaked credentials.

**File.** [`scripts/01_provision_azure.sh`](../scripts/01_provision_azure.sh):

```bash
az vm identity assign -g "$RG" -n "$VM_NAME" -o none
VM_PRINCIPAL_ID="$(az vm show -g "$RG" -n "$VM_NAME" --query identity.principalId -o tsv)"
```

The principal ID is then captured into `.state` for the next provisioning step.

**The three role assignments (the RBAC part).** Same file, immediately after the principal ID is captured:

```bash
# Key Vault Secrets User - lets the CVM read leafkey-<chain>-pem secrets
az role assignment create \
  --assignee-object-id "$VM_PRINCIPAL_ID" \
  --role "Key Vault Secrets User" \
  --scope "$(az keyvault show -g $RG -n $KV_NAME --query id -o tsv)"

# Key Vault Crypto Service Release User - lets the CVM invoke release_key on
# SKR-gated wrap keys. Architecturally invoked even though Path 3 skips it.
az role assignment create \
  --assignee-object-id "$VM_PRINCIPAL_ID" \
  --role "Key Vault Crypto Service Release User" \
  --scope "$(az keyvault show -g $RG -n $KV_NAME --query id -o tsv)"

# Storage Blob Data Reader - lets the CVM download cert chains from blob
az role assignment create \
  --assignee-object-id "$VM_PRINCIPAL_ID" \
  --role "Storage Blob Data Reader" \
  --scope "$(az storage account show -g $RG -n $SA_NAME --query id -o tsv)"
```

The scope is *resource-specific*, not subscription-wide — the CVM can read this vault and this storage account, nothing else.

---

## 3. Confidential VM (TEE boundary)

### 3.1 AMD SEV-SNP boundary

**What it represents.** The hardware trust boundary. AMD SEV-SNP encrypts the CVM's RAM with a key generated inside the AMD Secure Processor, unreachable from the host hypervisor or any other tenant on the same physical hardware. Microsoft can't read your CVM's memory; neither can a malicious neighbor.

**File.** Not a script — a hardware property of the `Standard_DC2as_v5` SKU. The diagnostic is in [`scripts/cvm-bootstrap.sh`](../scripts/cvm-bootstrap.sh) near the end:

```bash
dmesg | grep -iE 'sev|encryption' | head -3
```

You should see `Memory Encryption Features active: AMD SEV` in `dmesg`. That's the platform-level proof.

**The Path 3 caveat.** The *platform-level* boundary is real and active. What's *not* active in Path 3 is the *guest-initiated* SEV-SNP attestation — see section 4.1 below.

### 3.2 nginx + OpenSSL 3.5

**What it represents.** The TLS terminator. nginx is built against a source-built OpenSSL 3.5 (in `/opt/openssl/`) so it has native ML-KEM and ML-DSA. It listens on port 443 and serves whatever chain is currently symlinked active.

**Files.**
- [`scripts/cvm-bootstrap.sh`](../scripts/cvm-bootstrap.sh) — runs inside the CVM during step 03; builds OpenSSL 3.5, installs nginx.
- [`nginx/nginx.conf`](../nginx/nginx.conf) — the server config. Critical lines:

```nginx
listen 443 ssl;
http2 on;
ssl_certificate     /etc/pqc-sdv/active/fullchain.pem;
ssl_certificate_key /etc/pqc-sdv/active/leaf.key;
ssl_protocols       TLSv1.3;
ssl_conf_command Groups X25519MLKEM768:x25519:secp256r1;
```

The `ssl_conf_command Groups ...` line is the *server-side* announcement that the server will accept hybrid PQC. Without it, OpenSSL 3.5 still defaults to classical-only.

### 3.3 `/etc/pqc-sdv/`

**What it represents.** The on-CVM directory tree that holds the active chain's material. Structured as:

```
/etc/pqc-sdv/
├── env                     # KV_URI, MAA_URI, SA_BLOB_URL — sourced by switch
├── keys/
│   ├── classical.key       # ECDSA-P256 leaf private key
│   ├── mixed.key           # ECDSA-P256 leaf private key
│   └── pqc.key             # ML-DSA-44 leaf private key
├── certs/
│   ├── classical.fullchain.pem
│   ├── mixed.fullchain.pem
│   └── pqc.fullchain.pem
└── active/
    ├── leaf.key            # → symlink to keys/<chain>.key
    └── fullchain.pem       # → symlink to certs/<chain>.fullchain.pem
```

**Files.**
- [`scripts/cvm-bootstrap.sh`](../scripts/cvm-bootstrap.sh) — creates the directory tree with `mkdir -p` and sets ownership to `root:nginx` mode 750.
- [`nginx/nginx-switch.sh`](../nginx/nginx-switch.sh) — performs the symlink swap atomically with `ln -sf`.

**Why symlinks?** Atomic swap. `ln -sf` replaces a symlink in one syscall, so nginx (which dereferences the symlink at `SSL_CTX_use_certificate_chain_file()` time) never sees a half-written state. A `reload` then picks up the new target.

### 3.4 `fetch-skr-key.py` (Python)

**What it represents.** The script that runs inside the CVM, authenticates as the managed identity, and materializes the chain's TLS material from Azure into local files. Called by `nginx-switch.sh`.

**File.** [`scripts/fetch-skr-key.py`](../scripts/fetch-skr-key.py). The five-step flow described in the diagram corresponds to these lines:

```python
# 1. Get AAD token via IMDS
cred = ManagedIdentityCredential()

# 2. (Path 3) Architecturally: attest → release wrap key
print("[1/3] live SEV-SNP attestation skipped on this kernel build")

# 3. Fetch leaf key from Key Vault as a secret
secret_client = SecretClient(vault_url=KV_URI, credential=cred)
leaf_key = secret_client.get_secret(f"leafkey-{chain}-pem")

# 4. Fetch cert chain from blob
blob_client = BlobServiceClient(SA_BLOB_URL, credential=cred)
chain_pem = blob_client.get_blob_client("certs", f"{chain}/fullchain.pem") \
                       .download_blob().readall()

# 5. Decrypt (not needed in Path 3 — they're already in plaintext)
#    Write to /etc/pqc-sdv/keys/<chain>.key + certs/<chain>.fullchain.pem
```

The numbered comments correspond to the [3]–[6] flow arrows in the diagram.

### 3.5 sshd (port 22)

**What it represents.** The CVM's SSH daemon, used by the operator to provision and to trigger chain switches. Key-authenticated only; no password.

**Files.**
- [`scripts/01_provision_azure.sh`](../scripts/01_provision_azure.sh) — creates the CVM with an SSH public key (generated on-demand at `~/.ssh/pqc-sdv-cvm.pub` if it doesn't exist):

```bash
az vm create -g "$RG" -n "$VM_NAME" \
    --admin-username azureuser \
    --ssh-key-values "$(cat ~/.ssh/pqc-sdv-cvm.pub)" \
    ...
```

- [`scripts/03_bootstrap_cvm.sh`](../scripts/03_bootstrap_cvm.sh), [`scripts/04_start_nginx.sh`](../scripts/04_start_nginx.sh) — both invoke `ssh -i ~/.ssh/pqc-sdv-cvm azureuser@$PIP`.

**Diagram correspondence.** The dashed gray line from "Provisioning scripts" / "04_start_nginx.sh" to "sshd (port 22)" is this SSH path.

---

## 4. Attestation & key services

### 4.1 Microsoft Azure Attestation (MAA)

**What it represents.** The Azure service that verifies SEV-SNP attestation reports and issues signed JWTs. A CVM running Path-1 attestation would: read its SEV-SNP report from `/dev/sev-guest`, send it to MAA, receive a JWT containing the verified TEE claims, present that JWT to Key Vault as proof of running inside a genuine SEV-SNP CVM.

**Files.**
- [`scripts/01_provision_azure.sh`](../scripts/01_provision_azure.sh) — creates the MAA provider:

```bash
az attestation create -g "$RG" -n "$MAA_NAME" -l "$LOC"
MAA_URI="$(az attestation show -g "$RG" -n "$MAA_NAME" --query attestUri -o tsv)"
```

The URI is captured into `.state` and later written to `/etc/pqc-sdv/env` on the CVM.

- [`certs/skr-policy.json.tmpl`](../certs/skr-policy.json.tmpl) — the SKR release policy template that's attached to each Key Vault wrap key. It says "release this key if the request carries a JWT signed by *this* MAA provider, claiming TEE type SEV-SNP, with attributes matching this CVM's expected measurement."

**The Path 3 caveat.** As of mid-2026, the standard Azure CVM Ubuntu 22.04 confidential VM image (kernel `6.8.0-1053-azure-fde`) does *not* expose `/dev/sev-guest` to the guest. Guest-initiated attestation isn't available. [`fetch-skr-key.py`](../scripts/fetch-skr-key.py) detects this and falls back to managed-identity RBAC. The MAA provider, wrap keys, and SKR policies all exist and are correctly configured — when the image alignment ships, the same architecture works with attestation without any changes. See [`docs/LIMITATIONS.md`](LIMITATIONS.md#1-live-sev-snp-attestation-is-skipped-in-runtime-path-path-3).

That's why arrows [1] and [2] in the diagram are dotted: they're the architecturally-intended path but not the runtime path.

### 4.2 Azure Key Vault Premium

**What it represents.** The vault holding two kinds of cryptographic objects:

**Wrap keys** — RSA-HSM 4096-bit keys, one per chain (`wrap-key-classical`, `wrap-key-mixed`, `wrap-key-pqc`). Each has a release policy that says "this key may only be released to a caller who presents a valid MAA JWT certifying the requesting environment." This is the Secure Key Release (SKR) mechanism. Wrap keys never leave the vault unencrypted — when "released" to a CVM, they're wrapped under a session key only the CVM can decrypt inside its encrypted RAM.

**Secrets** — PEM-encoded leaf private keys, one per chain (`leafkey-classical-pem`, etc.). These are protected by Key Vault's RBAC (the `Key Vault Secrets User` role assignment) rather than SKR. In a fully production deployment, the leaf keys would be wrapped under the corresponding wrap key and released only after attestation. In this demo, they're stored as RBAC-protected secrets directly because the leaf keys themselves are small enough to fit (the cert chains aren't — see section 5.1).

**Files.**
- [`scripts/01_provision_azure.sh`](../scripts/01_provision_azure.sh) — `az keyvault create` with `--sku premium` and `--enable-purge-protection`. The script also handles the soft-delete edge case (purges any leftover from a prior demo).
- [`scripts/02_import_keys_and_blobs.sh`](../scripts/02_import_keys_and_blobs.sh) — for each chain:

```bash
# Create the SKR-gated wrap key
az keyvault key create --vault-name "$KV_NAME" -n "wrap-key-$chain" \
    --kty RSA-HSM --size 4096 \
    --release-policy @"$tmpdir/skr-policy.json" \
    --exportable

# Import the leaf private key as a secret
az keyvault secret set --vault-name "$KV_NAME" \
    --name "leafkey-$chain-pem" \
    --file "$LEAF_KEY_PEM" \
    --encoding base64 \
    --description "PEM-encoded leaf private key for $chain chain"
```

- [`certs/skr-policy.json.tmpl`](../certs/skr-policy.json.tmpl) — the SKR release policy. Templated so the actual MAA URI substitutes in at provision time.

---

## 5. Storage & networking

### 5.1 Azure Blob Storage

**What it represents.** A storage account with a `certs` container holding the cert chain PEM files. Public material — anyone in possession of a valid CA chain can present it; the secret is the *private key*, which lives in Key Vault. So the public chain doesn't need vault-level protection.

**Why blob and not Key Vault?** Azure Key Vault's per-secret size limit is **25,600 bytes**. The ML-DSA cert chains exceed this:

| Chain | Fullchain PEM size |
|---|---|
| classical | ~3 KB | ✅ fits |
| mixed | ~14 KB | ✅ fits |
| pqc | ~28 KB | ❌ **overflows** |

The first time you try to put a PQC fullchain into Key Vault you get:

```
(BadParameter) Secret is beyond the maximum permitted length of 25600 characters.
Inner error: { "code": "SecretTooLarge" }
```

Blob Storage doesn't have this limit. The architectural split — **Key Vault for keys, blob for chains** — is documented in [`docs/LIMITATIONS.md`](LIMITATIONS.md#1-azure-key-vaults-256-kb-secret-limit-overflows-for-ml-dsa-cert-chains). The split is also good practice independent of PQC: certs are public artifacts, keys are secrets.

**Files.**
- [`scripts/01_provision_azure.sh`](../scripts/01_provision_azure.sh) — creates the storage account and the `certs` container.
- [`scripts/02_import_keys_and_blobs.sh`](../scripts/02_import_keys_and_blobs.sh) — uploads the chains:

```bash
for chain in classical mixed pqc; do
  for file in fullchain.pem leaf.crt chain.pem; do
    az storage blob upload \
      --account-name "$SA_NAME" --account-key "$SA_KEY" \
      --container-name certs \
      --name "$chain/$file" \
      --file "certs/out/$chain/$file" \
      --overwrite
  done
done
```

### 5.2 NSG + Public IP

**What it represents.** A standard Azure Public IP attached to the CVM's NIC, with a Network Security Group attached to the subnet. The NSG locks the CVM's exposed surface to two ports, both source-restricted.

**Files.**
- [`scripts/01_provision_azure.sh`](../scripts/01_provision_azure.sh) — creates the NSG with two rules:

```bash
# Detect the operator's public IP at provision time
MY_IP="$(curl -s https://api.ipify.org)/32"

az network nsg rule create -g "$RG" --nsg-name "$NSG_NAME" \
    -n allow-ssh --priority 1000 --direction Inbound \
    --access Allow --protocol Tcp --destination-port-ranges 22 \
    --source-address-prefixes "$MY_IP"

az network nsg rule create -g "$RG" --nsg-name "$NSG_NAME" \
    -n allow-https --priority 1001 --direction Inbound \
    --access Allow --protocol Tcp --destination-port-ranges 443 \
    --source-address-prefixes "$MY_IP"
```

Default deny applies to everything else.

**Caveat.** If your laptop's public IP changes between runs (mobile networks, hotspot switch, VPN), the NSG no longer admits you. The fix is in [`docs/INSTALL.md`](INSTALL.md) under "Common issues — connection timed out" — refresh the NSG rule with the new IP.

---

## 6. The chain-switch sequence (numbered arrows [1]–[6])

Now that you've seen each box, here's the actual sequence when the operator runs `./scripts/04_start_nginx.sh pqc`:

| # | What | Where in code | File |
|---|---|---|---|
| **SSH** | Operator SSHes into the CVM as `azureuser` with the demo key, runs `nginx-switch.sh pqc` | `ssh -i ~/.ssh/pqc-sdv-cvm azureuser@$PIP ...` | [`scripts/04_start_nginx.sh`](../scripts/04_start_nginx.sh) |
| – | `nginx-switch.sh` sources `/etc/pqc-sdv/env` for `KV_URI`, `MAA_URI`, `SA_BLOB_URL` | `source /etc/pqc-sdv/env` | [`nginx/nginx-switch.sh`](../nginx/nginx-switch.sh) |
| – | Invokes `fetch-skr-key.py` with the chain name | `sudo -E env ... python /usr/local/bin/fetch-skr-key.py pqc` | [`nginx/nginx-switch.sh`](../nginx/nginx-switch.sh) |
| [1] | CVM requests a SEV-SNP report (or would, if `/dev/sev-guest` existed). Path 3: skipped. | `print("[1/3] live SEV-SNP attestation skipped on this kernel build")` | [`scripts/fetch-skr-key.py`](../scripts/fetch-skr-key.py) |
| [2] | MAA verifies the report and issues a JWT (would, in Path 1). Path 3: skipped. | not invoked | – |
| [3] | CVM authenticates as managed identity, requests the wrap key release + leaf secret from KV | `cred = ManagedIdentityCredential()` then `secret_client.get_secret(f"leafkey-{chain}-pem")` | [`scripts/fetch-skr-key.py`](../scripts/fetch-skr-key.py) |
| [4] | KV verifies the bearer token, checks RBAC, returns the secret. Wrapped key would be unwrapped in CVM RAM (Path 1); Path 3 returns the leaf PEM directly. | (KV-side, no code) | – |
| [5] | CVM downloads the cert chain blob | `blob_client.get_blob_client("certs", f"{chain}/fullchain.pem").download_blob().readall()` | [`scripts/fetch-skr-key.py`](../scripts/fetch-skr-key.py) |
| [6] | Blob Storage verifies the bearer token, checks RBAC, returns the PEM bytes | (blob-side, no code) | – |
| – | Switch script writes the key to `/etc/pqc-sdv/keys/pqc.key`, chain to `/etc/pqc-sdv/certs/pqc.fullchain.pem` | `OUT_KEYS / f"{chain}.key").write_text(leaf_key.value)` | [`scripts/fetch-skr-key.py`](../scripts/fetch-skr-key.py) |
| – | Switch script swaps `active/leaf.key` and `active/fullchain.pem` symlinks | `ln -sf keys/pqc.key /etc/pqc-sdv/active/leaf.key` | [`nginx/nginx-switch.sh`](../nginx/nginx-switch.sh) |
| – | nginx is started (or reloaded if already running) | `nginx -c /etc/pqc-sdv/nginx/nginx.conf -s reload` | [`nginx/nginx-switch.sh`](../nginx/nginx-switch.sh) |
| – | Local handshake test (s_client to 127.0.0.1) confirms the chain serves correctly | `/opt/openssl/bin/openssl s_client -connect 127.0.0.1:443 ...` | [`nginx/nginx-switch.sh`](../nginx/nginx-switch.sh) |

Total elapsed: 3–5 seconds. The CVM is now serving the requested chain.

## 7. The measurement path (purple solid line)

After a chain is loaded, the QEMU VCU performs the actual measured handshakes:

| # | What | Where in code | File |
|---|---|---|---|
| 1 | Operator triggers `make scenario CHAIN=pqc KEM=x25519mlkem768` on the laptop | `sshpass -p vcu ssh -p 12222 vcu@127.0.0.1 ...` | [`measure/Makefile`](../measure/Makefile) |
| 2 | The Make recipe SSHes into the VCU (port 12222 on the host, forwarded by QEMU to the guest's port 22) and runs a single multi-step shell command | (the `scenario:` recipe) | [`measure/Makefile`](../measure/Makefile) |
| 3 | Inside the VCU: start tshark capture on `enp0s2` with BPF filter `host <PIP> and port 443` | `tshark -i enp0s2 -w /tmp/hs.pcap -f 'host $(PIP) and port 443' & echo $! > /tmp/tshark.pid` | [`measure/Makefile`](../measure/Makefile) |
| 4 | Wait 3 seconds for the BPF filter to install | `sleep 3` | [`measure/Makefile`](../measure/Makefile) |
| 5 | Run N (default 20) back-to-back `openssl s_client` handshakes, each one hitting the CVM's public IP on port 443 with the chosen group | `/opt/openssl/bin/openssl s_client -connect $(PIP):443 -servername vcu-backend.local -groups $(KEM) -tls1_3 -brief </dev/null` | [`measure/Makefile`](../measure/Makefile) |
| 6 | Kill tshark with SIGINT (clean shutdown so the pcap is finalized) | `kill -INT $(cat /tmp/tshark.pid)` | [`measure/Makefile`](../measure/Makefile) |
| 7 | SCP the pcap back to the laptop | `sshpass scp ...:/tmp/hs.pcap $(RUN_DIR)/` | [`measure/Makefile`](../measure/Makefile) |
| 8 | Parse the pcap with `tshark -q -z conv,tcp` and extract per-flow byte counts (handling `bytes` vs `kB` units) | `re.findall(r"(\d+)\s+([\d,.]+)\s+(bytes\|kB\|MB\|kiB\|MiB)", line)` | [`measure/parse_pcap.py`](../measure/parse_pcap.py) |
| 9 | Compute per-flow durations from first-packet to last-packet timestamps | `dur_state[sid]["end"] = ts` | [`measure/parse_pcap.py`](../measure/parse_pcap.py) |
| 10 | Emit JSON with median, mean, p95 of total bytes / c2s bytes / s2c bytes / duration / segments | `print(json.dumps({...}, indent=2))` | [`measure/parse_pcap.py`](../measure/parse_pcap.py) |

After all four scenarios are run, `make report` aggregates them:

| # | What | Where in code | File |
|---|---|---|---|
| 11 | Read all `runs/*/metrics.json`, emit markdown table | `json.load(fh)` then print formatted rows | [`measure/make_report.py`](../measure/make_report.py) |
| 12 | Read all `runs/*/metrics.json`, plot a 4-panel bar chart | `axes[0,0].bar(labels, total, ...)` etc. | [`measure/make_chart.py`](../measure/make_chart.py) |

Outputs: `results.md` and `results.png`.

---

## 8. Teardown

When you're done measuring, **stop paying for the CVM**:

| # | What | File |
|---|---|---|
| 1 | Delete the resource group asynchronously (`--no-wait`) | [`scripts/99_teardown.sh`](../scripts/99_teardown.sh) |
| 2 | Purge the Key Vault soft-delete entry (so the name is reusable) | [`scripts/99_teardown.sh`](../scripts/99_teardown.sh) |
| 3 | Purge the MAA provider soft-delete entry | [`scripts/99_teardown.sh`](../scripts/99_teardown.sh) |
| 4 | Operator manually halts the QEMU VCU (Ctrl+A, X) | (no script) |

Verify with:

```bash
az group exists -n rg-pqc-sdv-demo   # should print "false"
```

The CVM bills ~$0.30/hr while running. Forgetting to tear down is the single most expensive mistake in this demo.

---

## Summary mapping table

For quick reference, every box in the diagram and its corresponding file(s):

| Diagram box | Primary file(s) |
|---|---|
| Operator + Azure CLI | [`scripts/00_prereqs.sh`](../scripts/00_prereqs.sh), [`scripts/env.sh`](../scripts/env.sh) |
| OpenSSL 3.5 (host) | [`certs/build_chains.sh`](../certs/build_chains.sh), [`certs/openssl.cnf.tmpl`](../certs/openssl.cnf.tmpl) |
| Provisioning scripts | [`scripts/01_provision_azure.sh`](../scripts/01_provision_azure.sh), [`02_import_keys_and_blobs.sh`](../scripts/02_import_keys_and_blobs.sh), [`03_bootstrap_cvm.sh`](../scripts/03_bootstrap_cvm.sh) |
| .state (gitignored) | written by [`scripts/01_provision_azure.sh`](../scripts/01_provision_azure.sh) |
| 04_start_nginx.sh `<chain>` | [`scripts/04_start_nginx.sh`](../scripts/04_start_nginx.sh) |
| QEMU VCU | [`qemu-client/Makefile`](../qemu-client/Makefile), [`qemu-client/user-data`](../qemu-client/user-data) |
| Measurement harness | [`measure/Makefile`](../measure/Makefile), [`parse_pcap.py`](../measure/parse_pcap.py) |
| Output artifacts | `measure/results.md`, `measure/results.png` |
| Azure Entra ID (AAD) | service-level — interacted with via `az login` and `ManagedIdentityCredential()` |
| Managed identity + 3 roles | [`scripts/01_provision_azure.sh`](../scripts/01_provision_azure.sh) |
| AMD SEV-SNP boundary | hardware property of the SKU; verified by `dmesg \| grep sev` in [`cvm-bootstrap.sh`](../scripts/cvm-bootstrap.sh) |
| nginx + OpenSSL 3.5 | [`nginx/nginx.conf`](../nginx/nginx.conf); built in [`scripts/cvm-bootstrap.sh`](../scripts/cvm-bootstrap.sh) |
| /etc/pqc-sdv/ | structure created by [`cvm-bootstrap.sh`](../scripts/cvm-bootstrap.sh), updated by [`nginx-switch.sh`](../nginx/nginx-switch.sh) |
| fetch-skr-key.py | [`scripts/fetch-skr-key.py`](../scripts/fetch-skr-key.py) |
| sshd (port 22) | configured by [`scripts/01_provision_azure.sh`](../scripts/01_provision_azure.sh) |
| Microsoft Azure Attestation | provider created by [`scripts/01_provision_azure.sh`](../scripts/01_provision_azure.sh); policy in [`certs/skr-policy.json.tmpl`](../certs/skr-policy.json.tmpl) |
| Azure Key Vault Premium | created by [`scripts/01_provision_azure.sh`](../scripts/01_provision_azure.sh); populated by [`02_import_keys_and_blobs.sh`](../scripts/02_import_keys_and_blobs.sh) |
| Azure Blob Storage | created by [`scripts/01_provision_azure.sh`](../scripts/01_provision_azure.sh); populated by [`02_import_keys_and_blobs.sh`](../scripts/02_import_keys_and_blobs.sh) |
| NSG + Public IP | [`scripts/01_provision_azure.sh`](../scripts/01_provision_azure.sh) |

Use this document alongside the diagram when reading the code, or when explaining the architecture to someone who needs the deep dive rather than the headline numbers.
