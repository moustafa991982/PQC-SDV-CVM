#!/usr/bin/env bash
# 01_provision_azure.sh - stand up everything in Azure.
#
# Resources created: RG, vNet, subnet, NSG (port 22 + 443 from your IP only),
# Public IP, NIC, Microsoft Azure Attestation provider, Key Vault Premium
# (RBAC mode), Storage Account + container, SEV-SNP confidential VM with
# system-assigned managed identity, and the RBAC role assignments wiring
# the CVM's identity to vault and blob.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

log "creating resource group ${RG} in ${LOC}"
az group create -n "$RG" -l "$LOC" --tags purpose=pqc-sdv-demo -o none

log "creating vnet/subnet/nsg/pip/nic"
az network vnet create -g "$RG" -n "$VNET_NAME" \
  --address-prefix 10.42.0.0/16 \
  --subnet-name "$SUBNET_NAME" --subnet-prefixes 10.42.1.0/24 -o none

az network nsg create -g "$RG" -n "$NSG_NAME" -o none
az network nsg rule create -g "$RG" --nsg-name "$NSG_NAME" \
  -n allow-ssh --priority 1000 \
  --source-address-prefixes "$ALLOWED_CIDR" \
  --destination-port-ranges 22 --access Allow --protocol Tcp -o none
az network nsg rule create -g "$RG" --nsg-name "$NSG_NAME" \
  -n allow-https --priority 1010 \
  --source-address-prefixes "$ALLOWED_CIDR" \
  --destination-port-ranges 443 --access Allow --protocol Tcp -o none
az network vnet subnet update -g "$RG" --vnet-name "$VNET_NAME" \
  -n "$SUBNET_NAME" --network-security-group "$NSG_NAME" -o none

az network public-ip create -g "$RG" -n "$PIP_NAME" \
  --sku Standard --allocation-method Static -o none
az network nic create -g "$RG" -n "$NIC_NAME" \
  --vnet-name "$VNET_NAME" --subnet "$SUBNET_NAME" \
  --public-ip-address "$PIP_NAME" -o none

# MAA provider
log "creating Microsoft Azure Attestation provider ${MAA_NAME}"
az attestation create -g "$RG" -n "$MAA_NAME" -l "$LOC" -o none \
  || warn "MAA provider may already exist or quota issue - continuing"
MAA_URI="$(az attestation show -g "$RG" -n "$MAA_NAME" --query attestUri -o tsv)"
log "  MAA URI: ${MAA_URI}"

# Handle soft-deleted Key Vault from prior teardowns
if az keyvault list-deleted --query "[?name=='${KV_NAME}'] | [0]" -o tsv 2>/dev/null | grep -q .; then
  warn "vault ${KV_NAME} exists in soft-deleted state; purging"
  az keyvault purge -n "$KV_NAME" --location "$LOC" || true
  sleep 10
fi

log "creating Key Vault Premium ${KV_NAME} (RBAC mode)"
az keyvault create -g "$RG" -n "$KV_NAME" -l "$LOC" \
  --sku premium \
  --retention-days 7 \
  -o none

# Grant the operator Key Vault Administrator on the new vault
USER_OBJ_ID="$(az ad signed-in-user show --query id -o tsv)"
SUB_ID="$(az account show --query id -o tsv)"
KV_SCOPE="/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.KeyVault/vaults/${KV_NAME}"

az role assignment create \
  --assignee "$USER_OBJ_ID" \
  --role "Key Vault Administrator" \
  --scope "$KV_SCOPE" -o none

# Storage account for cert chains
log "creating Storage Account ${SA_NAME}"
az storage account create -g "$RG" -n "$SA_NAME" -l "$LOC" \
  --sku Standard_LRS --kind StorageV2 \
  --allow-blob-public-access false -o none

SA_KEY="$(az storage account keys list -g "$RG" -n "$SA_NAME" --query [0].value -o tsv)"
az storage container create -n certs --account-name "$SA_NAME" --account-key "$SA_KEY" -o none

# The CVM
log "creating SEV-SNP confidential VM ${VM_NAME} (size ${VM_SIZE})"
az vm create -g "$RG" -n "$VM_NAME" \
  --size "$VM_SIZE" \
  --image "$VM_IMAGE" \
  --admin-username "$ADMIN_USER" \
  --ssh-key-values "$SSH_PUBKEY_FILE" \
  --nics "$NIC_NAME" \
  --security-type ConfidentialVM \
  --os-disk-security-encryption-type DiskWithVMGuestState \
  --enable-vtpm true \
  --enable-secure-boot true \
  --public-ip-sku Standard \
  -o none

log "enabling managed identity on CVM and granting RBAC roles"
az vm identity assign -g "$RG" -n "$VM_NAME" -o none
VM_PRINCIPAL_ID="$(az vm show -g "$RG" -n "$VM_NAME" --query identity.principalId -o tsv)"

# CVM needs: get secrets (leaf private keys), release keys (SKR), read blobs
az role assignment create \
  --assignee "$VM_PRINCIPAL_ID" \
  --role "Key Vault Secrets User" \
  --scope "$KV_SCOPE" -o none

az role assignment create \
  --assignee "$VM_PRINCIPAL_ID" \
  --role "Key Vault Crypto Service Release User" \
  --scope "$KV_SCOPE" -o none

SA_SCOPE="/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.Storage/storageAccounts/${SA_NAME}"
az role assignment create \
  --assignee "$VM_PRINCIPAL_ID" \
  --role "Storage Blob Data Reader" \
  --scope "$SA_SCOPE" -o none

# Persist state for downstream scripts
PIP="$(az network public-ip show -g "$RG" -n "$PIP_NAME" --query ipAddress -o tsv)"
STATE="${SCRIPT_DIR}/.state"
cat > "$STATE" <<EOF
RG=${RG}
VM_NAME=${VM_NAME}
PIP=${PIP}
KV_NAME=${KV_NAME}
KV_URI=https://${KV_NAME}.vault.azure.net
MAA_NAME=${MAA_NAME}
MAA_URI=${MAA_URI}
SA_NAME=${SA_NAME}
SA_BLOB_URL=https://${SA_NAME}.blob.core.windows.net
VM_PRINCIPAL_ID=${VM_PRINCIPAL_ID}
ADMIN_USER=${ADMIN_USER}
NSG_NAME=${NSG_NAME}
EOF

log ""
log "provisioning complete"
log "  CVM public IP: ${PIP}"
log "  Key Vault:     https://${KV_NAME}.vault.azure.net"
log "  MAA URI:       ${MAA_URI}"
log "  Blob URL:      https://${SA_NAME}.blob.core.windows.net"
log "state written to scripts/.state"
log "next: ./scripts/02_import_keys_and_blobs.sh"
