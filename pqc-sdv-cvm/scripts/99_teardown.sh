#!/usr/bin/env bash
# 99_teardown.sh - destroy the resource group, purge the Key Vault.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

read -p "really delete resource group ${RG}? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "aborted"; exit 0; }

KV_FOR_PURGE="$(az keyvault list -g "$RG" --query "[0].name" -o tsv 2>/dev/null || true)"

log "deleting resource group ${RG} (async)"
az group delete -n "$RG" --yes --no-wait

# Wait briefly then purge the Key Vault so its name is free for reuse
if [[ -n "${KV_FOR_PURGE:-}" ]]; then
  log "waiting 60s for vault to enter soft-deleted state"
  sleep 60
  log "purging soft-deleted vault ${KV_FOR_PURGE}"
  az keyvault purge -n "$KV_FOR_PURGE" --location "$LOC" --no-wait || true
fi

rm -f "${SCRIPT_DIR}/.state"
log "teardown initiated"
