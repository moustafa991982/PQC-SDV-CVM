# Installation guide

This walks through running the demo end-to-end, with every prerequisite, every script, what to expect, and what to do if it goes sideways. The full sequence on a fresh laptop takes about **45 minutes**, most of which is unattended (cloud-init builds inside the QEMU guest, Azure provisioning, etc.).

## Prerequisites

### Azure side

You need:
- An **Azure subscription** with permission to create resource groups in West Europe.
- **Confidential computing quota** for the `Standard_DC2as_v5` SKU in West Europe (or whichever region you change to). Check via `az vm list-usage --location westeurope --query "[?contains(name.value, 'DCas_v5')]"`.
- The owner role (or sufficient combined RBAC) to register resource providers, create role assignments, and provision Key Vault Premium.
- A **payment method on file**. The demo's running cost is approximately **$0.30/hour** while the CVM is up. A complete run-and-teardown costs under **$2** total.

### Laptop side

A Linux laptop with:
- **Ubuntu 22.04 or 24.04** (anything Debian-derived should work — these are tested).
- **x86_64 with virtualization extensions** (Intel VT-x or AMD-V). Run `egrep -c '(vmx|svm)' /proc/cpuinfo` — must be ≥ 1.
- **KVM enabled** — verify with `ls /dev/kvm`. If missing, enable virtualization in BIOS.
- **Network access** to: Azure ARM, `cloud-images.ubuntu.com`, GitHub, and your operator IP must be allowed to reach the CVM (the provisioning script auto-detects your public IP and adds the NSG rule).
- **At least 16 GB free disk** for the QEMU image, OpenSSL builds, and pcap captures.
- **Patience**.

## Step 0 — Install local prerequisites

```bash
git clone https://github.com/moustafa991982/pqc-sdv-cvm.git
cd pqc-sdv-cvm
./scripts/00_prereqs.sh
```

This installs:
- `azure-cli` (latest, via Microsoft's apt repository)
- `python3-pip`, `jq`, `make`, `gcc`, `build-essential`
- `qemu-system-x86`, `qemu-utils`, `cloud-image-utils`
- `tshark`, `sshpass`
- OpenSSL 3.5 from source into `/usr/local/openssl` (because Ubuntu 22.04/24.04 ship OpenSSL 3.0–3.3, none of which have native ML-KEM)

You'll be prompted to add your user to the `wireshark` group so tshark can capture without sudo. Accept it. **Log out and back in** before continuing (or run `newgrp wireshark` to activate the group in the current shell).

Verify OpenSSL has ML-KEM:

```bash
/usr/local/openssl/bin/openssl list -kem-algorithms | grep -i mlkem
```

Should print at least `MLKEM-768`. If not, the build failed — re-run `./scripts/00_prereqs.sh` and watch for errors.

## Step 1 — Authenticate to Azure

```bash
az login                                 # browser-based flow
az account show                          # verify the right subscription is active
az account set -s "<subscription-id>"    # if not
```

If this is the first time you've used confidential computing in this subscription, register the resource providers (the provisioning script also tries this, but doing it now avoids the segfault some `az` versions exhibit after RP registration):

```bash
for rp in Microsoft.Compute Microsoft.Network Microsoft.KeyVault \
          Microsoft.Storage Microsoft.Attestation Microsoft.ManagedIdentity \
          Microsoft.Authorization; do
  az provider register --namespace $rp
done

# Wait until they all show "Registered" — takes 1–2 minutes
az provider list --query "[?contains('$rp', namespace)].{ns:namespace, state:registrationState}" \
    -o table
```

Set a unique short prefix so multiple operators can share a subscription:

```bash
export DEMO_PREFIX="pqcdemo$(date +%s | tail -c 4)"   # e.g. pqcdemo3742
```

## Step 2 — Provision Azure (~5 minutes)

```bash
./scripts/01_provision_azure.sh
```

This creates, in `rg-pqc-sdv-demo`:

1. A virtual network and subnet, public IP, NSG with two rules:
   - `allow-https` — TCP/443 from your laptop's public IP only
   - `allow-ssh` — TCP/22 from your laptop's public IP only
2. The Confidential VM (`Standard_DC2as_v5`, Ubuntu 22.04 confidential VM image, AMD SEV-SNP). System-assigned managed identity. Boot diagnostics enabled.
3. **Microsoft Azure Attestation provider** (`<prefix>maa`) — region-specific endpoint that will verify SEV-SNP reports and issue signed JWTs.
4. **Azure Key Vault Premium** (`<prefix>kv`) — Premium tier is required for SKR. Created in RBAC permission model (not access policies).
5. **Storage account + blob container** (`<prefix>sa` with container `certs`) — holds the cert chain PEMs that exceed Key Vault's 25 KB secret limit.
6. **RBAC role assignments** on the CVM's managed identity:
   - `Key Vault Crypto Service Release User` on the vault
   - `Key Vault Secrets User` on the vault
   - `Storage Blob Data Reader` on the storage account

Outputs are written to `scripts/.state` for subsequent scripts to source.

Expected output:

```
[01] resource group ready: rg-pqc-sdv-demo (westeurope)
[01] vnet + subnet + public ip ready
[01] CVM ready - public IP: 4.180.176.55
[01] MAA endpoint: https://pqcdemo3742maa.weu.attest.azure.net
[01] Key Vault ready: https://pqcdemo3742kv.vault.azure.net
[01] Storage ready: https://pqcdemo3742sa.blob.core.windows.net
[01] RBAC: assigned 3 roles to CVM managed identity
[01] state written to scripts/.state
```

**Common issues:**

- *"The subscription is not registered to use namespace 'Microsoft.Attestation'"* — RP registration didn't propagate. Wait 60 seconds and re-run.
- *"SKU not available in region"* — the `Standard_DC2as_v5` quota isn't approved. Check `az vm list-usage --location westeurope`, request quota in the Portal, retry.
- *"The vault name is already in use"* — your prefix collided with an existing soft-deleted vault somewhere. The script auto-purges; if it persists, change `DEMO_PREFIX`.

## Step 3 — Build cert chains, import keys, upload blobs

```bash
./scripts/02_import_keys_and_blobs.sh
```

This script:

1. Runs `certs/build_chains.sh` which uses your local OpenSSL 3.5 to generate three full PKI chains under `certs/out/`. Root CA, sub-CA, and leaf for each of `classical`, `mixed`, `pqc`. Each chain's leaf has `CN=vcu-backend.example.com` and SAN `vcu-backend.local`.
2. For each chain, imports the leaf's private key into Key Vault as a **secret** (`leafkey-<chain>-pem`). PEM-encoded, with content type `application/x-pem-file`.
3. For each chain, creates a **wrap key** in Key Vault (`wrap-key-<chain>`, an RSA-HSM 4096-bit key) with an SKR release policy bound to the MAA provider. These are *architecturally* used to wrap the leaf private keys for SEV-SNP attested release. (See [LIMITATIONS.md#1](LIMITATIONS.md#1-live-sev-snp-attestation-is-skipped-in-runtime-path-path-3) for what actually happens at runtime.)
4. Uploads each chain's `fullchain.pem` and `leaf.pem` to the storage account's `certs` container.

Expected to take 2–3 minutes (mostly waiting on Key Vault key creation operations).

Verify:

```bash
source scripts/.state
az keyvault secret list --vault-name "$KV_NAME" -o table | grep leafkey
az keyvault key list    --vault-name "$KV_NAME" -o table | grep wrap-key
az storage blob list --account-name "$SA_NAME" -c certs --auth-mode login -o table
```

You should see three of each.

## Step 4 — Bootstrap the CVM (~5 minutes)

```bash
./scripts/03_bootstrap_cvm.sh
```

This SSHes into the CVM with your laptop's key pair (created on demand under `~/.ssh/pqc-sdv-cvm.*`) and:

1. Updates apt, installs `nginx`, `python3-pip`, `python3-venv`, `build-essential`.
2. Builds OpenSSL 3.5 from source into `/opt/openssl/` on the CVM (the system OpenSSL 3.0 doesn't have ML-KEM).
3. Sets up `/etc/pqc-sdv/{keys,certs,active}` directory tree owned by `root:nginx`, mode 750.
4. Installs `scripts/fetch-skr-key.py` to `/usr/local/bin/`, plus a Python virtualenv at `/opt/pqc-sdv-venv` with `azure-identity` and `azure-keyvault-secrets`.
5. Installs `nginx/nginx.conf` to `/etc/pqc-sdv/nginx/nginx.conf` (the CVM nginx is run with `nginx -c /etc/pqc-sdv/nginx/nginx.conf`).
6. Installs `nginx/nginx-switch.sh` to `/usr/local/bin/`.
7. Writes `/etc/pqc-sdv/env` with the Key Vault URI, MAA URI, and blob storage URL so scripts on the CVM can source it.
8. Verifies `dmesg | grep -i sev` shows AMD SEV memory encryption is active (proof of CVM platform).

If any step fails, the script halts and prints the SSH command to re-investigate.

Verify:

```bash
ssh -i ~/.ssh/pqc-sdv-cvm azureuser@$PIP "
  /opt/openssl/bin/openssl version
  ls -la /etc/pqc-sdv/
  dmesg | grep -iE 'sev|encryption' | head -3
"
```

You should see `OpenSSL 3.5.x`, the directory tree, and a line containing `AMD Memory Encryption Features active: SEV`.

## Step 5 — Start nginx on a chain

```bash
./scripts/04_start_nginx.sh classical
```

This SSHes in and runs the switch script, which:

1. Sources `/etc/pqc-sdv/env`.
2. Authenticates the Python helper as the CVM's managed identity.
3. Logs that SEV-SNP live attestation is being skipped on this kernel (Path 3).
4. Fetches `leafkey-classical-pem` from Key Vault, writes it to `/etc/pqc-sdv/keys/classical.key` (mode 600).
5. Fetches `certs/classical/fullchain.pem` and `leaf.pem` from blob, writes them to `/etc/pqc-sdv/certs/`.
6. Swaps `/etc/pqc-sdv/active/{key.pem,fullchain.pem}` symlinks to point at the `classical` files.
7. Starts (or reloads) nginx against `/etc/pqc-sdv/nginx/nginx.conf`.
8. Runs a local handshake test from inside the CVM to verify nginx accepts the chain.

You'll see output ending with `[switch] active chain: classical` and `[switch] ready - nginx on https://<IP>:443 serving chain=classical`.

Re-run with `mixed` or `pqc` to switch chains in 3–5 seconds.

**Common issues:**

- *"Access denied to Key Vault"* — RBAC propagation lag. Wait 60 seconds, retry.
- *"nginx: [emerg] open() '/var/log/nginx/error.log' failed (No such file or directory)"* — log dir wasn't created. Fix: `ssh azureuser@$PIP "sudo mkdir -p /var/log/nginx"`.
- *"the 'listen ... http2' directive is deprecated"* — warning only, nginx still works; fix is to change `listen 443 ssl http2;` to `listen 443 ssl;\n    http2 on;`.

## Step 6 — Boot the QEMU VCU

In a **separate terminal**:

```bash
cd qemu-client
make run-vm
```

This:

1. Downloads `noble-server-cloudimg-amd64.img` from `cloud-images.ubuntu.com` (~600 MB, first time only).
2. Creates `vcu.qcow2` overlay disk (16 GB).
3. Generates `seed.iso` from `user-data` + `meta-data` (cloud-init config).
4. Boots `qemu-system-x86_64 -enable-kvm -M q35 -cpu host -smp 2 -m 2048` with port 22 forwarded to host port 12222.

The VM logs stream to your terminal. cloud-init runs in the background after the login prompt appears, and **takes about 5–8 minutes** to build OpenSSL 3.5 inside the guest.

From a **third terminal**, poll for readiness:

```bash
sshpass -p vcu ssh -p 12222 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  vcu@127.0.0.1 \
  "test -x /opt/openssl/bin/openssl && echo READY || echo 'still building'"
```

Re-run every 60 seconds. When it prints `READY`, you can measure.

Sanity-check the VCU can reach the CVM:

```bash
source ../scripts/.state
sshpass -p vcu ssh -p 12222 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  vcu@127.0.0.1 \
  "/opt/openssl/bin/openssl s_client -connect ${PIP}:443 \
     -servername vcu-backend.local -groups X25519MLKEM768 -tls1_3 -brief \
     </dev/null 2>&1 | head -10"
```

You should see `CONNECTION ESTABLISHED`, `Protocol version: TLSv1.3`, `Negotiated TLS1.3 group: X25519MLKEM768`.

If you get **connection timed out**, your laptop's public IP has changed since `01_provision_azure.sh` ran. Refresh the NSG:

```bash
MY_IP="$(curl -s https://api.ipify.org)/32"
az network nsg rule update -g "$RG" --nsg-name "$NSG_NAME" \
  -n allow-https --source-address-prefixes "$MY_IP" -o none
```

## Step 7 — Run the measurement scenarios

```bash
cd measure
```

The Makefile defines four scenarios. Each:
1. SSHes into the VCU.
2. Starts `tshark` capturing on the guest's `enp0s2` interface, filtered to `host <PIP> and port 443`.
3. After 3 seconds (BPF filter installation), runs 20 back-to-back `openssl s_client` handshakes.
4. Sends `SIGINT` to tshark, waits 1 second.
5. Copies the pcap back to `runs/<chain>_<kem>/hs.pcap`.
6. Parses with `parse_pcap.py` → `metrics.json`.

Run them in order:

```bash
# Scenario 1 — classical chain + classical KEM (baseline, today's TLS)
make scenario CHAIN=classical KEM=x25519

# Scenario 2 — classical chain + hybrid PQC KEM (HNDL defense, recommended 2026 posture)
make scenario CHAIN=classical KEM=x25519mlkem768

# Switch CVM to mixed chain (ML-DSA root and sub-CA, ECDSA leaf)
( cd .. && ./scripts/04_start_nginx.sh mixed )
make scenario CHAIN=mixed KEM=x25519mlkem768

# Switch CVM to pqc chain (ML-DSA everywhere)
( cd .. && ./scripts/04_start_nginx.sh pqc )
make scenario CHAIN=pqc KEM=x25519mlkem768
```

Each scenario takes about 30–45 seconds. After each, the printed `metrics.json` should show:
- `"session_count": 20` (or very close)
- Populated `handshake_total_bytes`, `handshake_c2s_bytes`, `handshake_s2c_bytes` (not null)
- Populated `tcp_segments_per_session`
- Populated `handshake_duration_ms`

If any field is null or session_count is 0, see the **measurement troubleshooting** section below.

## Step 8 — Generate the chart and table

```bash
make report
```

This reads all four `runs/*/metrics.json` files and produces:

- `results.md` — markdown table of median, mean, p95 for each scenario
- `results.png` — 2×2 bar chart (four panels: total bytes, S→C bytes, duration, TCP segments)

The numbers won't be exactly the same as the ones in `assets/results-example.png` (your WAN latency differs, BBR vs Cubic, etc.), but the *shape* should be very similar. The 2.4 KB hybrid-KEM cost and the 18 KB PKI-boundary jump are properties of the algorithms, not the network.

## Step 9 — Tear down (critical!)

The CVM costs ~$0.30/hour. When you're done:

```bash
cd ..
./scripts/99_teardown.sh
```

This:
1. Stops the QEMU VCU (you may want to do this manually first — press `Ctrl+A` then `X` in the QEMU terminal).
2. Deletes the resource group asynchronously (`--no-wait`).
3. Purges the Key Vault soft-deleted entry (vault names are scarce; this lets you reuse `DEMO_PREFIX` later).
4. Purges the MAA provider soft-deleted entry similarly.

Verify the resource group is gone after 5 minutes:

```bash
az group exists -n rg-pqc-sdv-demo
# false means you're no longer being billed
```

## Measurement troubleshooting

### `session_count: 0` after `make scenario`

The pcap captured no traffic. Causes:

1. **tshark interface name** — the Makefile assumes `enp0s2` on the x86_64 guest. If your guest uses `ens3` or similar, change the Makefile: `sed -i 's|-i enp0s2|-i ens3|' Makefile`.
2. **tshark capabilities missing** — dumpcap must have `cap_net_raw,cap_net_admin=eip`. Fix: `sshpass -p vcu ssh -p 12222 vcu@127.0.0.1 "sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/dumpcap"`.
3. **tshark race condition** — the Makefile uses `sleep 3` after backgrounding tshark to give BPF time to install. On slower laptops, increase to `sleep 5`.

### `session_count: 20` but bytes are `null`

The pcap captured but `parse_pcap.py` couldn't extract byte counts. Almost always because tshark's `conv,tcp` output uses different units (`bytes` vs `kB`) than the parser's regex handles. The parser in this repo handles both; if you've modified it and broken something, regenerate from the version in `measure/parse_pcap.py`.

### Handshake works manually but `make scenario` fails

Check `runs/<scenario>/hs.log` — it contains the stdout of all 20 openssl invocations. If they show errors like `unsafe legacy renegotiation disabled`, your OpenSSL config on the VCU is stricter than the CVM's. The s_client flag `-legacy_server_connect` works around it (but shouldn't be needed for fresh handshakes).

### Stale SSH known_hosts after VM rebuild

If you destroy and recreate the QEMU VCU, `~/.ssh/known_hosts` will have a stale entry for `[127.0.0.1]:12222` that blocks reconnection. The Makefile already passes `-o UserKnownHostsFile=/dev/null` to bypass; if you're manually SSHing, either pass the same option or `ssh-keygen -f ~/.ssh/known_hosts -R "[127.0.0.1]:12222"`.

## What success looks like

After step 7, your `measure/runs/` directory contains four scenario folders, each with a `metrics.json` showing real numbers. After step 8, `measure/results.png` and `measure/results.md` summarize them.

If you can run the four scenarios and produce a chart whose shape matches `assets/results-example.png` (deltas, not absolute numbers), the demo is working correctly and your environment is sound.
