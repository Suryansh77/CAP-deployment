#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

umask 077

CA_KEY="upstream-ca.key"
CA_CERT="upstream-ca.crt"
SERVER_KEY="upstream-server.key"
SERVER_CSR="upstream-server.csr"
SERVER_CERT="upstream-server.crt"
SERIAL_FILE="upstream-ca.srl"

CA_SUBJECT="/O=Zamp Test Environment/OU=Egress Verification/CN=Zamp Upstream Test CA"
SERVER_SUBJECT="/O=Zamp Test Environment/OU=Egress Verification/CN=egress-test.customer-egress.svc.cluster.local"

cat > ca-openssl.cnf <<'EOF'
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no

[req_distinguished_name]
O = Zamp Test Environment
OU = Egress Verification
CN = Zamp Upstream Test CA

[v3_ca]
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

cat > server-openssl.cnf <<'EOF'
[req]
distinguished_name = req_distinguished_name
prompt = no

[req_distinguished_name]
O = Zamp Test Environment
OU = Egress Verification
CN = egress-test.customer-egress.svc.cluster.local

[server_cert]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = DNS:egress-test.customer-egress.svc.cluster.local,DNS:egress-test
EOF

rm -f \
  "${CA_KEY}" \
  "${CA_CERT}" \
  "${SERVER_KEY}" \
  "${SERVER_CSR}" \
  "${SERVER_CERT}" \
  "${SERIAL_FILE}"

openssl genrsa -out "${CA_KEY}" 2048

openssl req \
  -x509 \
  -new \
  -sha256 \
  -days 30 \
  -key "${CA_KEY}" \
  -out "${CA_CERT}" \
  -config ca-openssl.cnf

openssl genrsa -out "${SERVER_KEY}" 2048

openssl req \
  -new \
  -sha256 \
  -key "${SERVER_KEY}" \
  -out "${SERVER_CSR}" \
  -config server-openssl.cnf

openssl x509 \
  -req \
  -sha256 \
  -days 30 \
  -in "${SERVER_CSR}" \
  -CA "${CA_CERT}" \
  -CAkey "${CA_KEY}" \
  -CAcreateserial \
  -out "${SERVER_CERT}" \
  -extfile server-openssl.cnf \
  -extensions server_cert

rm -f "${SERVER_CSR}" "${SERIAL_FILE}"

chmod 600 "${CA_KEY}" "${SERVER_KEY}"
chmod 644 "${CA_CERT}" "${SERVER_CERT}"

echo "Generated:"
echo "  ${CA_CERT}"
echo "  ${SERVER_CERT}"

echo
echo "CA extensions:"
openssl x509 \
  -in "${CA_CERT}" \
  -noout \
  -text | grep -A3 -E "Basic Constraints|Key Usage|Subject Key Identifier|Authority Key Identifier"

echo
echo "Server extensions:"
openssl x509 \
  -in "${SERVER_CERT}" \
  -noout \
  -text | grep -A3 -E "Basic Constraints|Key Usage|Extended Key Usage|Subject Key Identifier|Authority Key Identifier|Subject Alternative Name"

echo
echo "Chain verification:"
openssl verify \
  -CAfile "${CA_CERT}" \
  "${SERVER_CERT}"