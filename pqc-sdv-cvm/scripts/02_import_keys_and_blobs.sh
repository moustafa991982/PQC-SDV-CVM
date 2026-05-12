#!/usr/bin/env bash
# 02_import_keys_and_blobs.sh - push the three chains' material to Azure.
#
# For each chain:
#   - Leaf private key goes to Key Vault as a secret (leafkey-<chain>-pem)
#   - An SKR-policy-protected RSA-HSM wrap key is created (wrapkey-<chain>)
#     -- the wrap key release policy is bound to MAA, gating future
#     -- attestation-based access. The leaf secret itself is RBAC-protected.
#   - Cert chain files go to Blob Storage at certs/<chain>/{fullchain.pem,
#     leaf.crt, chain.pem}. Blob is used because ML-DSA full chains exceed
#     Key Vault's 25.6 KB secret limit (see docs/LIMITATIONS.md).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/.state"

CERTS_DIR="$(cd "${SCRIPT_DIR}/../certs" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Render SKR policy bound to our MAA URI
MAA_URI="$MAA_URI" envsubst < "${CERTS_DIR}/skr-policy.json.tmpl" \
  > "${TMP}/skr-policy.json"
log "SKR policy bound to MAA: ${MAA_URI}"

SA_KEY="$(az storage account keys list -g "$RG" -n "$SA_NAME" --query [0].value -o tsv)"

for chain in "${CHAINS[@]}"; do
  d="${CERTS_DIR}/out/${chain}"
  wrap_key="wrapkey-${chain}"
  log "=== chain: ${chain} ==="

  # 1. SKR-gated wrap key. We use RSA-HSM because EC keys can't wrap;
  #    --exportable true is required for release_key to work at all.
  log "  creating wrap key ${wrap_key} with SKR policy"
  az keyvault key create --vault-name "$KV_NAME" -n "$wrap_key" \
    --kty RSA-HSM --size 4096 \
    --ops wrapKey unwrapKey \
    --policy "${TMP}/skr-policy.json" \
    --exportable true \
    -o none 2>/dev/null || warn "wrap key may already exist (continuing)"

  # 2. Leaf private key as a Key Vault secret. Fetched at runtime by the CVM.
  log "  storing leaf private key as secret leafkey-${chain}-pem"
  az keyvault secret set --vault-name "$KV_NAME" \
    -n "leafkey-${chain}-pem" \
    --file "${d}/leaf.key" \
    --tags "wrapped_under=${wrap_key}" "chain=${chain}" \
    -o none

  # 3. Cert chain files to Blob Storage
  log "  storing cert chain in blob"
  for f in fullchain.pem leaf.crt chain.pem; do
    az storage blob upload \
      --account-name "$SA_NAME" --account-key "$SA_KEY" \
      -c certs -n "${chain}/${f}" \
      -f "${d}/${f}" \
      --overwrite -o none
  done

  log "  ${chain} ok"
done

log ""
log "all keys + chains uploaded"
log ""
log "verify with:"
log "  az keyvault secret list --vault-name $KV_NAME -o table"
log "  az keyvault key list --vault-name $KV_NAME -o table"
log "  az storage blob list --account-name $SA_NAME --account-key '<KEY>' -c certs -o table"
log ""
log "next: ./scripts/03_bootstrap_cvm.sh"
