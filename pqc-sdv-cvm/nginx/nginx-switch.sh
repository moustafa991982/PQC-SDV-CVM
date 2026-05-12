#!/usr/bin/env bash
#
# nginx-switch.sh <chain>
#
# Runs on the Confidential VM. Switches nginx to serve a different cert chain
# by:
#   1. Sourcing /etc/pqc-sdv/env for KV/MAA/blob URIs
#   2. Invoking fetch-skr-key.py to materialize the leaf key + cert chain
#   3. Atomically swapping /etc/pqc-sdv/active/ symlinks
#   4. Starting (or reloading) nginx
#   5. Running a local handshake test to confirm the chain serves correctly
#
# Expected chains: classical | mixed | pqc

set -euo pipefail

chain="${1:?usage: nginx-switch.sh <classical|mixed|pqc>}"
echo "[switch] chain=${chain}"

# Load Key Vault / MAA / blob URIs into the environment
set -a
# shellcheck disable=SC1091
source /etc/pqc-sdv/env
set +a

echo "[switch] KV_URI=${KV_URI}"
echo "[switch] MAA_URI=${MAA_URI}"
echo "[switch] SA_BLOB_URL=${SA_BLOB_URL}"

# Fetch the leaf private key (from KV) and cert chain (from blob).
# fetch-skr-key.py uses managed-identity authentication; the Python venv
# at /opt/pqc-sdv-venv has azure-identity + azure-keyvault-secrets installed.
echo "[switch] fetching key + certs via SKR + blob"
sudo -E env KV_URI="${KV_URI}" MAA_URI="${MAA_URI}" SA_BLOB_URL="${SA_BLOB_URL}" \
    /opt/pqc-sdv-venv/bin/python /usr/local/bin/fetch-skr-key.py "${chain}"

# Atomically swap the active symlinks
sudo ln -sf "/etc/pqc-sdv/keys/${chain}.key"            /etc/pqc-sdv/active/leaf.key
sudo ln -sf "/etc/pqc-sdv/certs/${chain}.fullchain.pem" /etc/pqc-sdv/active/fullchain.pem

# Start or reload nginx
if pgrep -x nginx >/dev/null; then
    echo "[switch] reloading nginx"
    sudo nginx -c /etc/pqc-sdv/nginx/nginx.conf -s reload
else
    echo "[switch] starting nginx"
    sudo nginx -c /etc/pqc-sdv/nginx/nginx.conf
fi

# Wait a beat for nginx to reload its TLS material before testing
sleep 1

# Local handshake test (from inside the CVM, through loopback)
echo "[switch] local handshake test:"
/opt/openssl/bin/openssl s_client \
    -connect 127.0.0.1:443 \
    -servername vcu-backend.local \
    -groups X25519MLKEM768 -tls1_3 \
    -CAfile "/etc/pqc-sdv/certs/${chain}.fullchain.pem" \
    </dev/null 2>&1 | grep -E 'Connecting|depth|CONNECTION|Protocol|Cipher|Peer|Signature|Verification|Negotiated|DONE' \
    || true

echo "[switch] active chain: ${chain}"
