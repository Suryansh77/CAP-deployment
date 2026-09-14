#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${SCRIPT_DIR}/certs"

REGISTRY_HOST="${REGISTRY_HOST:-host.docker.internal}"
REGISTRY_ORG="${REGISTRY_ORG:-Local Customer}"
CA_NAME="${CA_NAME:-Local Customer Registry CA}"

CA_KEY="${CERT_DIR}/ca.key"
CA_CERT="${CERT_DIR}/ca.crt"
REGISTRY_KEY="${CERT_DIR}/registry.key"
REGISTRY_CERT="${CERT_DIR}/registry.crt"

mkdir -p "${CERT_DIR}"
umask 077

if [[ -f "${CA_KEY}" && -f "${CA_CERT}" && -f "${REGISTRY_KEY}" && -f "${REGISTRY_CERT}" ]]; then
  echo "LOCAL_REGISTRY_CERTS_EXIST"
  openssl verify \
    -CAfile "${CA_CERT}" \
    "${REGISTRY_CERT}"
  exit 0
fi

rm -f \
  "${CA_KEY}" \
  "${CA_CERT}" \
  "${REGISTRY_KEY}" \
  "${REGISTRY_CERT}" \
  "${CERT_DIR}/registry.csr" \
  "${CERT_DIR}/ca.srl" \
  "${CERT_DIR}/registry.ext"

echo "Generating local customer-like registry CA..."

openssl genrsa \
  -out "${CA_KEY}" \
  4096

cat > "${CERT_DIR}/ca.cnf" <<EOF_CA
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no

[req_distinguished_name]
C = IN
O = ${REGISTRY_ORG}
OU = Platform Security
CN = ${CA_NAME}

[v3_ca]
basicConstraints = critical, CA:true, pathlen:1
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF_CA

openssl req \
  -x509 \
  -new \
  -sha256 \
  -days 3650 \
  -key "${CA_KEY}" \
  -out "${CA_CERT}" \
  -config "${CERT_DIR}/ca.cnf"

echo "Generating registry server key..."

openssl genrsa \
  -out "${REGISTRY_KEY}" \
  2048

openssl req \
  -new \
  -sha256 \
  -key "${REGISTRY_KEY}" \
  -out "${CERT_DIR}/registry.csr" \
  -subj "/C=IN/O=${REGISTRY_ORG}/OU=Platform Security/CN=${REGISTRY_HOST}"

cat > "${CERT_DIR}/registry.ext" <<EOF_EXT
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = DNS:${REGISTRY_HOST},DNS:localhost
EOF_EXT

echo "Signing registry certificate..."

openssl x509 \
  -req \
  -sha256 \
  -days 825 \
  -in "${CERT_DIR}/registry.csr" \
  -CA "${CA_CERT}" \
  -CAkey "${CA_KEY}" \
  -CAcreateserial \
  -out "${REGISTRY_CERT}" \
  -extfile "${CERT_DIR}/registry.ext"

rm -f \
  "${CERT_DIR}/registry.csr" \
  "${CERT_DIR}/ca.srl" \
  "${CERT_DIR}/registry.ext" \
  "${CERT_DIR}/ca.cnf"

chmod 600 "${CA_KEY}" "${REGISTRY_KEY}"
chmod 644 "${CA_CERT}" "${REGISTRY_CERT}"

echo
echo "=== Certificate verification ==="

openssl x509 \
  -in "${CA_CERT}" \
  -noout \
  -subject \
  -issuer \
  -dates

openssl x509 \
  -in "${REGISTRY_CERT}" \
  -noout \
  -subject \
  -issuer \
  -dates

openssl verify \
  -CAfile "${CA_CERT}" \
  "${REGISTRY_CERT}"

echo
echo "REGISTRY_CERTS_OK"
echo "Registry host: ${REGISTRY_HOST}"
echo "Organization: ${REGISTRY_ORG}"
echo "CA name: ${CA_NAME}"
