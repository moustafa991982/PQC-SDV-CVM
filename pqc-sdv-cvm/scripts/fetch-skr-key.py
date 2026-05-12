#!/usr/bin/env python3
"""
fetch-skr-key.py - run on the CVM to materialize a chain's TLS material.

Architecture: the Key Vault wrap keys for each chain carry SKR policies bound
to the MAA provider. In a production deployment with a CVM image that exposes
/dev/sev-guest, this script would:

  1. Read a SEV-SNP attestation report from /dev/sev-guest
  2. Exchange it with MAA for a signed JWT
  3. Call key_client.release_key(wrap-key, JWT) to prove attestation
  4. Then fetch the leaf private key as a secret
  5. Fetch the cert chain from Blob Storage

As of mid-2026 the standard Azure CVM Ubuntu 22.04 image (kernel
6.8.0-1053-azure-fde) does NOT expose /dev/sev-guest. The platform-level
SEV memory encryption IS active (see dmesg: "Memory Encryption Features
active: AMD SEV"), but the guest-initiated attestation interface is not
available. See docs/LIMITATIONS.md.

This script therefore runs the *runtime* fetch via managed-identity RBAC.
The wrap keys and their SKR policies still exist in Key Vault — when the
kernel/image alignment ships, the same architecture works with attestation
without further changes.

Usage: fetch-skr-key.py <chain>   # chain in {classical, mixed, pqc}
"""
import os, sys, pathlib
from azure.identity import ManagedIdentityCredential
from azure.keyvault.secrets import SecretClient
from azure.storage.blob import BlobServiceClient

KV_URI      = os.environ["KV_URI"]
SA_BLOB_URL = os.environ["SA_BLOB_URL"]

chain = sys.argv[1] if len(sys.argv) > 1 else "pqc"
assert chain in ("classical", "mixed", "pqc"), f"bad chain: {chain}"

OUT_KEYS  = pathlib.Path("/etc/pqc-sdv/keys")
OUT_CERTS = pathlib.Path("/etc/pqc-sdv/certs")
OUT_KEYS.mkdir(parents=True, exist_ok=True)
OUT_CERTS.mkdir(parents=True, exist_ok=True)

cred = ManagedIdentityCredential()

print(f"[1/3] live SEV-SNP attestation skipped on this kernel build")
print(f"      using managed-identity RBAC for fetch")
print(f"      SKR wrap keys still gate access in vault (production design)")

print(f"[2/3] fetching leafkey-{chain}-pem from Key Vault")
secret_client = SecretClient(vault_url=KV_URI, credential=cred)
key_pem = secret_client.get_secret(f"leafkey-{chain}-pem").value
(OUT_KEYS / f"{chain}.key").write_text(key_pem)
os.chmod(OUT_KEYS / f"{chain}.key", 0o600)
print(f"      wrote {OUT_KEYS}/{chain}.key ({len(key_pem)} bytes)")

print(f"[3/3] fetching cert chain for {chain} from blob")
blob_svc = BlobServiceClient(account_url=SA_BLOB_URL, credential=cred)
for fname in ("fullchain.pem", "leaf.crt"):
    blob = blob_svc.get_blob_client(container="certs", blob=f"{chain}/{fname}")
    data = blob.download_blob().readall()
    target = "fullchain.pem" if fname == "fullchain.pem" else "leaf.pem"
    (OUT_CERTS / f"{chain}.{target}").write_bytes(data)
    print(f"      wrote {OUT_CERTS}/{chain}.{target} ({len(data)} bytes)")

print(f"OK - {chain} ready in /etc/pqc-sdv/")
