#!/usr/bin/env bash
# 04_start_nginx.sh - tell the CVM to serve a given chain.
# Usage: ./04_start_nginx.sh <classical|mixed|pqc>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/.state"

chain="${1:?usage: $0 <classical|mixed|pqc>}"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

log "switching CVM to chain=${chain}"
ssh ${SSH_OPTS} "${ADMIN_USER}@${PIP}" "/usr/local/bin/nginx-switch.sh ${chain}"

log "ready - nginx on https://${PIP}:443 serving chain=${chain}"
log "next: cd qemu-client && make run-vm"
