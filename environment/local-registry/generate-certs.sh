#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${SCRIPT_DIR}/certs"

# Override these for another environment/customer.
REGISTRY_HOST="${REGISTRY_HOST:-host.docker.internal}"
REGISTRY_ORG="${REGISTRY_ORG:-Local Customer}"
CA_NAME="${CA_NAME:-Local Customer Registry CA}"

mkdir -p "$CERT_DIR"

echo "Generating local customer-like registry CA..."
openssl genrsa -out "$CERT_DIR/ca.key" 4096

openssl req -x509 -new -nodes \
  -key "$CERT_DIR/ca.key" \
  -sha256 \
  -days 3650 \
  -out "$CERT_DIR/ca.crt" \
  -subj "/C=IN/O=${REGISTRY_ORG}/OU=Platform Security/CN=${CA_NAME}"

echo "Generating registry server key..."
openssl genrsa -out "$CERT_DIR/registry.key" 2048

openssl req -new \
  -key "$CERT_DIR/registry.key" \
  -out "$CERT_DIR/registry.csr" \
  -subj "/C=IN/O=${REGISTRY_ORG}/OU=Platform Security/CN=${REGISTRY_HOST}"

cat > "$CERT_DIR/registry.ext" <<EXTEOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${REGISTRY_HOST}
EXTEOF

echo "Signing registry certificate..."
openssl x509 -req \
  -in "$CERT_DIR/registry.csr" \
  -CA "$CERT_DIR/ca.crt" \
  -CAkey "$CERT_DIR/ca.key" \
  -CAcreateserial \
  -out "$CERT_DIR/registry.crt" \
  -days 825 \
  -sha256 \
  -extfile "$CERT_DIR/registry.ext"

echo
echo "=== Certificate verification ==="
openssl x509 \
  -in "$CERT_DIR/registry.crt" \
  -noout \
  -subject \
  -issuer \
  -dates

openssl verify \
  -CAfile "$CERT_DIR/ca.crt" \
  "$CERT_DIR/registry.crt"

echo
echo "Registry host: $REGISTRY_HOST"
echo "Organization: $REGISTRY_ORG"
echo "CA name: $CA_NAME"
echo "Certificate material generated under: $CERT_DIR"
