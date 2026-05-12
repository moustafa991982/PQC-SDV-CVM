# Limitations encountered

A catalogue of everything that didn't work as the docs implied, and what we did about it. Possibly the most useful section of this repo for anyone planning a similar deployment.

## 1. Azure Key Vault's 25.6 KB secret limit overflows for ML-DSA cert chains

**What we hit.** Tried to store a full PQC cert chain (ML-DSA-87 root + ML-DSA-65 sub-CA + ML-DSA-44 leaf) as a Key Vault secret. The raw `fullchain.pem` is **26,838 bytes**. Key Vault rejected the upload with:

```
(BadParameter) Secret is beyond the maximum permitted length of 25600 characters.
Inner error: { "code": "SecretTooLarge" }
```

**Why this happens.** Azure Key Vault's per-secret size limit is 25,600 characters of secret value. It was sized for RSA-4096 and ECDSA-P521 keys, which fit comfortably. ML-DSA cert chains exceed it by ~5%.

**What we did.** Cert chains moved to Azure Blob Storage. Only the leaf private keys remain in Key Vault. The CVM's managed identity has `Key Vault Secrets User` (for the private keys) and `Storage Blob Data Reader` (for the chains). The threat model is unchanged — cert chains are public artifacts; only the private keys need vault-level protection anyway.

**Generalizable insight.** Cloud key-management infrastructure was sized for a pre-PQC world. Anyone planning a PQC deployment on Azure / AWS / GCP should expect to surface this in their first sprint and design around it. The "Key Vault for keys, blob for artifacts" pattern is the right answer regardless of PQC — it just becomes mandatory once your cert chains are large.

## 2. Azure CVM Ubuntu 22.04 image doesn't expose `/dev/sev-guest`

**What we hit.** Built `fetch-skr-key.py` to attest the CVM by reading a SEV-SNP report via `/dev/sev-guest` and sending it to MAA. The device file doesn't exist:

```bash
$ ls -la /dev/sev-guest
ls: cannot access '/dev/sev-guest': No such file or directory
```

**What's actually present.** `dmesg` confirms SEV memory encryption is active:

```
[    0.485226] Memory Encryption Features active: AMD SEV
```

But `/proc/cpuinfo` shows the CPU flag is `sme` (Secure Memory Encryption), not `sev_snp`. The `sev-guest` kernel module isn't loaded and isn't present in `/lib/modules/$(uname -r)`. The Azure CVM image we used (`Canonical:0001-com-ubuntu-confidential-vm-jammy:22_04-lts-cvm:latest`, kernel `6.8.0-1053-azure-fde`) has the **platform-level CVM boundary active** but does **not** expose the SEV-SNP guest-attestation interface.

**What we did.** Documented this as "Path 3" — skip the live attestation step at runtime, fetch the wrap key and secret via managed-identity RBAC instead. The Key Vault wrap keys still carry SKR policies bound to the MAA provider, so the *architecture* is correct for the production attestation flow. The runtime call is omitted in this build.

**Generalizable insight.** "Confidential VM" on Azure is a platform property (memory encryption + isolated TPM + attested boot), and SEV-SNP guest attestation is a separate kernel/userspace property. The combination of "DCasv5 SKU + jammy-cvm image + kernel 6.8" as of mid-2026 ships with the former and not the latter. Anyone building real attestation flows in 2026 needs to either pick an image with `sev-guest` working (some newer or community images do) or use the `azguestattestation` library through alternative kernel paths.

For LinkedIn/post purposes, this is itself a finding: **even on Microsoft's own cloud, the kernel/image alignment for end-to-end guest attestation lags behind the platform availability**.

## 3. New Azure subscriptions need explicit resource-provider registration

**What we hit.** First `az keyvault create` returned:

```
(MissingSubscriptionRegistration) The subscription is not registered to use namespace 'Microsoft.KeyVault'.
```

Subsequently the same happened for `Microsoft.Storage`:

```
(SubscriptionNotFound) Subscription <...> was not found.
```

**Why this happens.** Azure ARM doesn't auto-register resource providers when the CLI invokes them for the first time. The Portal does silently. The CLI doesn't.

**What we did.** `00_prereqs.sh` now explicitly registers `Microsoft.KeyVault`, `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.Attestation`, `Microsoft.ManagedIdentity`, and `Microsoft.Authorization` at the top of the script. Registration takes 30–60 seconds per namespace; the script polls until each one is `Registered`.

**Generalizable insight.** When using `az` against a fresh subscription, always run `az provider register --namespace <NS>` for every RP you'll touch. The error messages are misleading ("SubscriptionNotFound" actually means "subscription not registered for this provider"). Surfacing this once at prereq-check time is much friendlier than letting it fail at random points in provisioning.

## 4. Key Vault Premium defaults to RBAC mode, not access-policy mode

**What we hit.** First `az keyvault set-policy` invocation returned:

```
Cannot set policies to a vault with '--enable-rbac-authorization' specified
```

**Why this happens.** Key Vault has two permission models — the older "access policies" (per-vault ACL) and the newer Azure RBAC (role assignments at any scope). Newly-created vaults default to RBAC. The two modes are mutually exclusive — `set-policy` only works in access-policy mode.

**What we did.** Switched the scripts to use Azure RBAC throughout. Operator gets `Key Vault Administrator`; the CVM's managed identity gets `Key Vault Secrets User` + `Key Vault Crypto Service Release User`. Two narrow roles instead of one broad policy, which is also cleaner from a least-privilege standpoint.

**Generalizable insight.** RBAC mode is the correct production choice anyway (granular, audit-logged, scoped). But it changes how scripts grant permissions — and the propagation time is 30–60 seconds, which causes spurious `Forbidden` errors immediately after role assignment if you don't pause.

## 5. Tshark output format varies with byte magnitudes

**What we hit.** The `parse_pcap.py` regex correctly extracted handshake byte counts for the `classical` scenarios (~4 KB) but reported `session_count: 0` for `mixed` and `pqc` scenarios with ~20-25 KB handshakes.

**Why this happens.** `tshark -z conv,tcp` switches its output format unit based on magnitude:

```
10.0.2.15:45382  <->  4.180.176.55:443    23  21 kB    23  2,785 bytes    46  24 kB
```

Below ~10 KB, tshark labels values as `bytes`. Above that, it switches to `kB`. The same row can mix units in different columns. The original regex matched only the `bytes` suffix.

**What we did.** Generalized the regex to accept `bytes|kB|MB|kiB|MiB` and added a `to_bytes()` helper that converts based on the unit string.

**Generalizable insight.** Avoid parsing tshark's human-readable output for measurement scripts. Use `-T fields` with explicit field names where possible, or `-T json` for structured output. The `conv,tcp` table is convenient but format-fragile across magnitudes and tshark versions.

## 6. QEMU ARM64 emulation breaks Ubuntu 24.04 systemd

**What we hit.** Initial QEMU "VCU" was Ubuntu 24.04 ARM64 (to mimic real automotive Cortex-A SoCs). Boot froze 140 seconds in with:

```
[143.06] systemd[1]: Failed to fork off sandboxing environment for executing generators: Protocol error
[143.06] !!!!!!] Failed to start up manager.
[143.11] systemd[1]: Freezing execution.
```

**Why this happens.** systemd 255 (Ubuntu 24.04) exercises kernel features (CLONE_NEWUSER + seccomp + ambient capabilities + cgroup v2) that don't reliably work under pure QEMU emulation of ARM64 on an x86 host. KVM acceleration isn't available for cross-architecture emulation.

**What we did.** Switched the guest to **Ubuntu 24.04 amd64 with KVM acceleration**. Boot time dropped from "fails after 140 seconds" to ~30 seconds. The demo's claim that the VCU matches automotive Cortex-A was a "nice-to-have" — not a requirement — and the post-quantum measurements don't depend on guest architecture. amd64 with KVM is faster, more stable, and equally valid for measuring TLS wire costs.

**Generalizable insight.** Pure QEMU emulation has rough edges for modern Linux. If KVM is available on the host, use it — even if it means changing guest architecture. The benchmark is the *network* path, not the *CPU* path, so guest arch doesn't matter.

## 7. SSH known-hosts pollution when CVMs and QEMU VMs are recreated

**What we hit.** Every time the Azure CVM or QEMU VCU was recreated (different host key fingerprint), subsequent SSH commands failed with:

```
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
Permission denied (publickey,password).
```

**Why this happens.** SSH's `StrictHostKeyChecking=accept-new` records each host's key on first connection. When the host is recreated, the new fingerprint disagrees with the saved one, and SSH refuses to even attempt password auth (sshpass never gets its chance).

**What we did.** Switched to `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR` for all demo SSH commands. This explicitly opts out of host-key checking for demo throwaway VMs.

**Generalizable insight.** For local-only or short-lived demo infrastructure, point SSH at `/dev/null` for known_hosts. For production, use the opposite extreme — strict checking with provisioned known_hosts files. The accept-new default is fine for human use but breaks scripts the second the infrastructure rotates.

## 8. tshark needs capabilities, not sudo, after setcap

**What we hit.** First measurement scenarios produced empty pcaps (0 bytes captured, 20 successful handshakes in the log). The Makefile ran tshark via `sudo`, which counterintuitively *broke* it.

**Why this happens.** On Ubuntu, `dumpcap` ships with file capabilities `cap_net_admin,cap_net_raw=eip` and is in the `wireshark` group. Running tshark **as the regular user** picks up these capabilities via dumpcap. Running with `sudo` resets the environment and runs as root, but **root with setuid doesn't get file capabilities** — the security model is that file caps replace setuid, not augment it.

**What we did.** Removed `sudo` from all tshark/pkill commands in the Makefile. The `vcu` user is in the `wireshark` group and can capture directly.

**Generalizable insight.** When a binary has file capabilities, *don't* run it with sudo. The file caps are the auth mechanism; sudo just creates a different (root) execution context that doesn't have them.

## 9. The QEMU interface name isn't `enp0s1`

**What we hit.** Even with `sudo` fixed, tshark captures still came back empty. The Makefile assumed `-i enp0s1` but the actual interface name in the amd64 guest was `enp0s2`.

**Why this happens.** ARM64 vs amd64 KVM/QEMU configurations enumerate virtio-net devices on different PCI buses. The naming convention `enp<bus>s<slot>` picks up the actual bus number.

**What we did.** Patched the Makefile to use `enp0s2`. The README documents how to check the actual name (`ip -br link` inside the guest) and how to override it.

**Generalizable insight.** Hardcoded interface names in measurement scripts will eventually bite. Either auto-detect (`ip -j addr show | jq ...`) or document the override.

## 10. tshark capture races the openssl loop

**What we hit.** After fixing the interface name, the pcap was 400 bytes (just the BPF header, zero packets captured). The Makefile started tshark in the background via one SSH session, then opened a *second* SSH session to run the openssl loop. By the time openssl ran, tshark's BPF filter wasn't yet installed.

**Why this happens.** SSH sessions don't share process trees. The first SSH backgrounds tshark and returns immediately. tshark's BPF filter takes ~100ms to compile and install. The second SSH starts and runs openssl in <100ms.

**What we did.** Collapsed into a single SSH session: start tshark in the background, `sleep 3` to ensure BPF is up, run the openssl loop, kill tshark cleanly.

**Generalizable insight.** Async setup of a capture before running the thing you're measuring needs an explicit wait — either polling for capture readiness, or a conservative sleep. Two-SSH-session designs invite races.

## 11. Stale soft-deleted Key Vault names block re-creation

**What we hit.** After running teardown and re-running provisioning with the same prefix:

```
(ConflictError) A vault with the same name already exists in deleted state.
You need to either recover or purge existing key vault.
```

**Why this happens.** Key Vault Premium has 7-day soft-delete by default. Deleting the resource group doesn't immediately free the global name — the soft-deleted vault still reserves it.

**What we did.** The provisioning script now checks for soft-deleted vaults under the chosen name and purges them automatically:

```bash
if az keyvault list-deleted --query "[?name=='${KV_NAME}'] | [0]" -o tsv | grep -q .; then
  warn "vault ${KV_NAME} exists in soft-deleted state; purging"
  az keyvault purge -n "$KV_NAME" --location "$LOC"
fi
```

The teardown script also explicitly purges to avoid leaving the name reserved.

**Generalizable insight.** Soft-delete semantics differ between resources (vaults: 7 days, storage accounts: depending on retention, etc.). Idempotent provisioning needs to know about each one.

## 12. Az CLI segfaults on some operations after provider registration

**What we hit.** Once during the session, `az keyvault create` died with:

```
/usr/bin/az: line 3: 13171 Segmentation fault (core dumped)
```

**Why this happens.** Az CLI caches API versions per provider. When `Microsoft.KeyVault` flips from `NotRegistered` to `Registered`, the cache goes stale; the next CLI invocation can hit pointer issues in the Python bindings.

**What we did.** Clearing the cache fixed it:

```bash
rm -rf ~/.azure/commandIndex.json ~/.azure/cache
```

**Generalizable insight.** Az CLI cache invalidation lags provider state changes. After any `az provider register` that flips state, clear the cache before the next operation in that namespace.

---

## What this list is NOT

This isn't an indictment of Azure or the PQC ecosystem — it's a snapshot of what "the road less traveled" looks like in 2026. Confidential VMs, SEV-SNP attestation, Key Vault SKR, and ML-DSA/ML-KEM are all relatively new at this scale. Most of these issues will be smoothed over by 2027–2028 as the tooling matures.

Documenting them honestly is more useful than pretending the path was clean. Anyone planning a real PQ-protected SDV cloud backend will hit these (and others). The point of this section is to compress that learning curve.
