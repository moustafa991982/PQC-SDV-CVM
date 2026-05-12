#!/usr/bin/env bash
# cvm-bootstrap.sh - runs INSIDE the SEV-SNP CVM after copy-in.
# Idempotent: skips OpenSSL/nginx build if they're already present.

set -euo pipefail
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
exec > >(tee -a /var/log/cvm-bootstrap.log) 2>&1
echo "[bootstrap] starting at $(date -u)"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
  build-essential cmake ninja-build pkg-config \
  git curl jq ca-certificates \
  libssl-dev libpcre3-dev zlib1g-dev \
  python3 python3-pip libcurl4-openssl-dev

# --- OpenSSL 3.5 (native ML-KEM, ML-DSA) ---
if [[ ! -x /opt/openssl/bin/openssl ]]; then
  echo "[bootstrap] building OpenSSL 3.5"
  cd /usr/local/src
  curl -sSLO https://www.openssl.org/source/openssl-3.5.0.tar.gz
  tar xf openssl-3.5.0.tar.gz
  cd openssl-3.5.0
  ./Configure --prefix=/opt/openssl --openssldir=/opt/openssl no-shared
  make -j"$(nproc)"
  make install_sw
fi
export PATH=/opt/openssl/bin:$PATH
echo 'export PATH=/opt/openssl/bin:$PATH' > /etc/profile.d/openssl-3.5.sh

cat > /opt/openssl/openssl.cnf <<'CONF_END'
openssl_conf = openssl_init

[openssl_init]
providers = provider_sect

[provider_sect]
default = default_sect

[default_sect]
activate = 1
CONF_END

export OPENSSL_CONF=/opt/openssl/openssl.cnf
echo 'export OPENSSL_CONF=/opt/openssl/openssl.cnf' >> /etc/profile.d/openssl-3.5.sh

echo "[bootstrap] verifying PQC support in OpenSSL"
/opt/openssl/bin/openssl list -kem-algorithms 2>/dev/null | grep -iE 'ml-kem' \
  || echo "(no ML-KEM listed - check OpenSSL version)"
/opt/openssl/bin/openssl list -signature-algorithms 2>/dev/null | grep -iE 'ml-dsa' \
  || echo "(no ML-DSA listed - check OpenSSL version)"

# --- nginx against OpenSSL 3.5 ---
if [[ ! -x /opt/nginx/sbin/nginx ]]; then
  echo "[bootstrap] building nginx against OpenSSL 3.5"
  cd /usr/local/src
  curl -sSLO https://nginx.org/download/nginx-1.27.4.tar.gz
  tar xf nginx-1.27.4.tar.gz
  cd nginx-1.27.4
  ./configure --prefix=/opt/nginx \
    --with-http_ssl_module --with-http_v2_module \
    --with-cc-opt="-I/opt/openssl/include" \
    --with-ld-opt="-L/opt/openssl/lib64 -Wl,-rpath,/opt/openssl/lib64"
  make -j"$(nproc)"
  make install
fi

# nginx needs /var/log/nginx/ to exist
mkdir -p /var/log/nginx

# --- Python SDKs ---
pip3 install --quiet --break-system-packages \
  azure-identity azure-keyvault-keys azure-keyvault-secrets \
  azure-storage-blob requests cryptography 2>/dev/null \
  || pip3 install --quiet azure-identity azure-keyvault-keys \
       azure-keyvault-secrets azure-storage-blob requests cryptography

# --- directory layout ---
mkdir -p /etc/pqc-sdv/certs /etc/pqc-sdv/keys /etc/pqc-sdv/nginx /etc/pqc-sdv/active
chmod 700 /etc/pqc-sdv/keys

echo "[bootstrap] complete at $(date -u)"
echo "[bootstrap] OpenSSL: $(/opt/openssl/bin/openssl version)"
echo "[bootstrap] nginx:   $(/opt/nginx/sbin/nginx -v 2>&1)"
