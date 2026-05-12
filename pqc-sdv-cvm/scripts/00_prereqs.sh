#!/usr/bin/env bash
# 00_prereqs.sh - verify the laptop and the Azure subscription are ready.
# Run this once before everything else.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

require() {
  local cmd="$1" hint="${2:-install via your package manager}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "missing: $cmd ($hint)"
  fi
}

log "checking laptop tooling"
require az    "https://learn.microsoft.com/cli/azure/install-azure-cli"
require jq
require openssl
require qemu-system-x86_64 "apt install qemu-system-x86"
require qemu-img
require tshark "apt install tshark"
require cloud-localds "apt install cloud-image-utils"
require make
require curl
require ssh
require sshpass "apt install sshpass"

# OpenSSL 3.5+ for native ML-KEM / ML-DSA support
ossl_ver="$(openssl version | awk '{print $2}')"
log "openssl $ossl_ver"
if [[ "$(printf '3.5.0\n%s\n' "$ossl_ver" | sort -V | head -1)" != "3.5.0" ]]; then
  warn "openssl < 3.5; PQC cert generation will use oqs-provider (still works)"
fi

# KVM available?
if [[ -e /dev/kvm ]]; then
  log "kvm available at /dev/kvm"
else
  warn "KVM not available; QEMU will use pure emulation (slow but works)"
fi

# Logged into Azure?
if ! az account show >/dev/null 2>&1; then
  die "not logged into az; run 'az login'"
fi
SUB_ID="$(az account show --query id -o tsv)"
SUB_NAME="$(az account show --query name -o tsv)"
log "azure subscription: $SUB_NAME ($SUB_ID)"

# Register all the resource providers we need. New subscriptions ship with
# many of these unregistered; the CLI does NOT auto-register.
log "ensuring resource providers are registered"
for ns in Microsoft.KeyVault Microsoft.Compute Microsoft.Network \
          Microsoft.Storage Microsoft.Attestation \
          Microsoft.ManagedIdentity Microsoft.Authorization; do
  state="$(az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || echo NotRegistered)"
  if [[ "$state" != "Registered" ]]; then
    log "  registering $ns (this can take 30-60s)"
    az provider register --namespace "$ns" -o none
    for i in {1..30}; do
      state="$(az provider show --namespace "$ns" --query registrationState -o tsv)"
      [[ "$state" == "Registered" ]] && break
      sleep 5
    done
    [[ "$state" == "Registered" ]] || die "$ns did not register; check portal"
  fi
  log "  $ns: $state"
done

# DCasv5 quota check (the most common gotcha)
log "checking ${LOC} for DCasv5 quota and SKU availability"
avail="$(az vm list-skus -l "$LOC" --size Standard_DC --query "[?name=='${VM_SIZE}'].name | [0]" -o tsv)" || true
if [[ -z "$avail" ]]; then
  warn "${VM_SIZE} not listed in ${LOC} - try westeurope, northeurope, eastus, or eastus2"
fi

quota_limit="$(az vm list-usage -l "$LOC" --query "[?contains(localName, 'DCasv5')].limit | [0]" -o tsv 2>/dev/null || echo 0)"
if [[ -z "$quota_limit" || "$quota_limit" == "0" ]]; then
  warn "DCasv5 quota is 0 in ${LOC}. Request quota at:"
  warn "  Portal -> Subscriptions -> Usage + quotas -> filter 'DCasv5'"
  warn "  Request at least 8 vCPUs. Microsoft auto-approves small requests."
else
  log "DCasv5 quota: $quota_limit vCPUs available"
fi

# SSH key
[[ -f "$SSH_PUBKEY_FILE" ]] || die "ssh pubkey not found at $SSH_PUBKEY_FILE; run 'ssh-keygen'"
log "ssh pubkey ok: $SSH_PUBKEY_FILE"

# tshark needs cap_net_raw on dumpcap, or membership in wireshark group
if ! groups | grep -qw wireshark; then
  warn "user $USER is not in the 'wireshark' group; tshark will need sudo"
  warn "  fix: sudo usermod -aG wireshark $USER && newgrp wireshark"
fi

log ""
log "all prereqs ok"
log "next: ./certs/build_chains.sh"
