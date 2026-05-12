#!/usr/bin/env bash
# 03_bootstrap_cvm.sh - copy bootstrap helper and configuration to the CVM,
# then run the bootstrap script remotely.
#
# The on-CVM bootstrap builds OpenSSL 3.5 from source (Ubuntu 22.04 ships
# 3.0, which lacks native ML-KEM/ML-DSA), builds nginx against it, installs
# the Python Azure SDKs, and prepares /etc/pqc-sdv/.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/.state"

# Use a project-local known_hosts so we don't pollute ~/.ssh/known_hosts
# (the CVM's host key changes every time it's rebuilt)
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SSH="ssh ${SSH_OPTS}"
SCP="scp ${SSH_OPTS}"

log "waiting for SSH on ${PIP}"
for i in {1..30}; do
  if $SSH "${ADMIN_USER}@${PIP}" 'echo ok' 2>/dev/null | grep -q ok; then break; fi
  sleep 5
done

log "copying bootstrap + helper scripts to CVM"
$SCP "${SCRIPT_DIR}/cvm-bootstrap.sh" \
     "${SCRIPT_DIR}/fetch-skr-key.py" \
     "${ADMIN_USER}@${PIP}:/tmp/"

log "running bootstrap on CVM (takes ~8 min - building OpenSSL + nginx)"
$SSH "${ADMIN_USER}@${PIP}" "sudo bash /tmp/cvm-bootstrap.sh"

log "installing fetch-skr-key.py to /usr/local/bin/"
$SSH "${ADMIN_USER}@${PIP}" "sudo install -m 0755 /tmp/fetch-skr-key.py /usr/local/bin/fetch-skr-key.py"

log "writing /etc/pqc-sdv/env on CVM"
$SSH "${ADMIN_USER}@${PIP}" "sudo tee /etc/pqc-sdv/env >/dev/null" <<EOF
export KV_URI=${KV_URI}
export MAA_URI=${MAA_URI}
export SA_BLOB_URL=${SA_BLOB_URL}
EOF

log "copying nginx configs"
$SCP -r "${SCRIPT_DIR}/../nginx/" "${ADMIN_USER}@${PIP}:/tmp/nginx-confs"
$SSH "${ADMIN_USER}@${PIP}" "sudo cp -r /tmp/nginx-confs/* /etc/pqc-sdv/nginx/ && sudo install -m 0755 /tmp/nginx-confs/nginx-switch.sh /usr/local/bin/nginx-switch.sh"

log ""
log "CVM bootstrapped"
log "next: ./scripts/04_start_nginx.sh <classical|mixed|pqc>"
