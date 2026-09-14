#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${SCRIPT_DIR}/certs"

CA_KEY="${CERT_DIR}/mitmproxy-ca.key"
CA_CERT="${CERT_DIR}/mitmproxy-ca-cert.pem"
CA_BUNDLE="${CERT_DIR}/mitmproxy-ca.pem"

mkdir -p "${CERT_DIR}"
umask 077

validate_existing_ca() {
  openssl x509 \
    -in "${CA_CERT}" \
    -noout \
    -checkend 86400 \
    >/dev/null

  openssl x509 \
    -in "${CA_CERT}" \
    -noout \
    -text |
    grep -q "CA:TRUE"
}

if [[ -f "${CA_KEY}" && -f "${CA_CERT}" && -f "${CA_BUNDLE}" ]]; then
  if validate_existing_ca; then
    echo "CUSTOMER_EGRESS_CA_EXISTS"
    exit 0
  fi

  echo "Existing customer egress CA is invalid or expires within 24 hours; regenerating."
fi

rm -f "${CA_KEY}" "${CA_CERT}" "${CA_BUNDLE}"

echo "Generating customer egress CA..."

openssl genrsa \
  -out "${CA_KEY}" \
  4096

openssl req \
  -x509 \
  -new \
  -sha256 \
  -days 365 \
  -key "${CA_KEY}" \
  -out "${CA_CERT}" \
  -subj "/O=Zamp Customer/OU=Egress Security/CN=Zamp Customer Egress CA" \
  -addext "basicConstraints=critical,CA:true,pathlen:1" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  -addext "authorityKeyIdentifier=keyid:always"

cat "${CA_KEY}" "${CA_CERT}" > "${CA_BUNDLE}"

chmod 600 "${CA_KEY}"
chmod 644 "${CA_CERT}" "${CA_BUNDLE}"

echo
openssl x509 \
  -in "${CA_CERT}" \
  -noout \
  -subject \
  -issuer \
  -dates

echo
echo "CUSTOMER_EGRESS_CA_OK"
