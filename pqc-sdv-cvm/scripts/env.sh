# scripts/env.sh - source this in every other script
# Edit values to match your subscription.

# --- you almost certainly want to change these ---
export LOC="${LOC:-westeurope}"                          # SEV-SNP DCasv5 region
export RG="${RG:-rg-pqc-sdv-demo}"
export PREFIX="${PREFIX:-pqcsdv$(whoami | tr -dc 'a-z0-9' | head -c4)}"
export ADMIN_USER="${ADMIN_USER:-azureuser}"
export SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-$HOME/.ssh/id_rsa.pub}"
export ALLOWED_CIDR="${ALLOWED_CIDR:-$(curl -s https://api.ipify.org)/32}"

# --- derived resource names ---
export VM_NAME="${PREFIX}-cvm"
export VNET_NAME="${PREFIX}-vnet"
export SUBNET_NAME="${PREFIX}-subnet"
export NSG_NAME="${PREFIX}-nsg"
export PIP_NAME="${PREFIX}-pip"
export NIC_NAME="${PREFIX}-nic"
export KV_NAME="${PREFIX}kv"
export MAA_NAME="${PREFIX}maa"
export SA_NAME="${PREFIX}sa"

# --- VM SKU and image ---
export VM_SIZE="${VM_SIZE:-Standard_DC2as_v5}"
export VM_IMAGE="Canonical:0001-com-ubuntu-confidential-vm-jammy:22_04-lts-cvm:latest"

# --- chains ---
export CHAINS=(classical mixed pqc)

# --- logging helpers used everywhere ---
export C_OK=$'\033[32m' C_WARN=$'\033[33m' C_ERR=$'\033[31m' C_NC=$'\033[0m' C_DIM=$'\033[2m'
log()  { echo "${C_OK}[$(date +%H:%M:%S)]${C_NC} $*"; }
warn() { echo "${C_WARN}[$(date +%H:%M:%S)] WARN${C_NC} $*"; }
die()  { echo "${C_ERR}[$(date +%H:%M:%S)] ERR${C_NC} $*" >&2; exit 1; }
