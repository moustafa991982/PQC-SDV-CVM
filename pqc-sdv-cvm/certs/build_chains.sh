#!/usr/bin/env bash
# build_chains.sh - mint all three V2G-style certificate chains locally.
#
# All chains share the same structure (root -> sub-CA -> leaf) and the same
# SAN/EKU. Only the algorithms differ:
#   classical: ECDSA-P256 / ECDSA-P256 / ECDSA-P256
#   mixed:     ML-DSA-87  / ML-DSA-65  / ECDSA-P256
#   pqc:       ML-DSA-87  / ML-DSA-65  / ML-DSA-44

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../scripts/env.sh"

OUT="${SCRIPT_DIR}/out"
TMPL="${SCRIPT_DIR}/openssl.cnf.tmpl"
SERVER_FQDN="${SERVER_FQDN:-vcu-backend.example.com}"

detect_pqc_provider() {
  if openssl list -providers 2>/dev/null | grep -q oqsprovider; then
    echo "oqs"
  elif openssl version | grep -qE '3\.[5-9]|[4-9]\.'; then
    echo "default"
  else
    die "need OpenSSL 3.5+ or oqs-provider for ML-DSA"
  fi
}

PROV="$(detect_pqc_provider)"
log "using PQC provider: $PROV"

algname() {
  case "$1" in
    ml-dsa-44|mldsa44) [[ "$PROV" = "oqs" ]] && echo "mldsa44" || echo "ML-DSA-44" ;;
    ml-dsa-65|mldsa65) [[ "$PROV" = "oqs" ]] && echo "mldsa65" || echo "ML-DSA-65" ;;
    ml-dsa-87|mldsa87) [[ "$PROV" = "oqs" ]] && echo "mldsa87" || echo "ML-DSA-87" ;;
    ec-p256)           echo "EC" ;;
    *) die "unknown alg $1" ;;
  esac
}

genkey() {
  local alg="$1" out="$2"
  case "$alg" in
    ec-p256)
      openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out" ;;
    ml-dsa-*)
      local n="$(algname "$alg")"
      openssl genpkey -algorithm "$n" -out "$out" ;;
  esac
}

render_cfg() {
  local cn="$1" ou="$2" outfile="$3"
  CN="$cn" OU="$ou" SERVER_FQDN="$SERVER_FQDN" \
    envsubst < "$TMPL" > "$outfile"
}

build_chain() {
  local name="$1" root_alg="$2" subca_alg="$3" leaf_alg="$4"
  local d="${OUT}/${name}"
  log "=== building chain: ${name} ==="
  log "    root=${root_alg}  subca=${subca_alg}  leaf=${leaf_alg}"
  mkdir -p "$d"

  # Root
  genkey "$root_alg" "${d}/root.key"
  render_cfg "PQC-SDV ${name} root" "Root CA" "${d}/root.cnf"
  openssl req -new -x509 -key "${d}/root.key" -days 3650 \
    -config "${d}/root.cnf" -extensions v3_root \
    -out "${d}/root.crt"

  # Sub-CA
  genkey "$subca_alg" "${d}/subca.key"
  render_cfg "PQC-SDV ${name} sub-CA" "Sub-CA" "${d}/subca.cnf"
  openssl req -new -key "${d}/subca.key" -config "${d}/subca.cnf" \
    -out "${d}/subca.csr"
  openssl x509 -req -in "${d}/subca.csr" -days 1825 \
    -CA "${d}/root.crt" -CAkey "${d}/root.key" -CAcreateserial \
    -extfile "${d}/subca.cnf" -extensions v3_subca \
    -out "${d}/subca.crt"

  # Leaf
  genkey "$leaf_alg" "${d}/leaf.key"
  render_cfg "$SERVER_FQDN" "VCU Backend" "${d}/leaf.cnf"
  openssl req -new -key "${d}/leaf.key" -config "${d}/leaf.cnf" \
    -out "${d}/leaf.csr"
  openssl x509 -req -in "${d}/leaf.csr" -days 365 \
    -CA "${d}/subca.crt" -CAkey "${d}/subca.key" -CAcreateserial \
    -extfile "${d}/leaf.cnf" -extensions v3_leaf \
    -out "${d}/leaf.crt"

  cat "${d}/leaf.crt" "${d}/subca.crt" > "${d}/chain.pem"
  cat "${d}/leaf.crt" "${d}/subca.crt" "${d}/root.crt" > "${d}/fullchain.pem"

  openssl verify -CAfile "${d}/root.crt" -untrusted "${d}/subca.crt" "${d}/leaf.crt" \
    || die "chain ${name} failed verification"

  {
    echo "chain=${name}"
    echo "root_alg=${root_alg}    root_size=$(stat -c%s "${d}/root.crt")"
    echo "subca_alg=${subca_alg}  subca_size=$(stat -c%s "${d}/subca.crt")"
    echo "leaf_alg=${leaf_alg}    leaf_size=$(stat -c%s "${d}/leaf.crt")"
    echo "chain_pem_size=$(stat -c%s "${d}/chain.pem")"
    echo "fullchain_size=$(stat -c%s "${d}/fullchain.pem")"
  } > "${d}/sizes.txt"

  log "chain ${name} ok ($(grep fullchain "${d}/sizes.txt"))"
}

mkdir -p "$OUT"
build_chain classical ec-p256   ec-p256   ec-p256
build_chain mixed     ml-dsa-87 ml-dsa-65 ec-p256
build_chain pqc       ml-dsa-87 ml-dsa-65 ml-dsa-44

log ""
log "all chains built. summary:"
for c in "${CHAINS[@]}"; do
  echo
  echo "--- ${c} ---"
  cat "${OUT}/${c}/sizes.txt"
done

log ""
log "next: ./scripts/01_provision_azure.sh"
