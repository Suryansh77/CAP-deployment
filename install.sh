#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-}"

if [[ -z "${TARGET}" ]]; then
  echo "Usage: ./install.sh local"
  exit 2
fi

case "${TARGET}" in
  local)
    ;;
  *)
    echo "ERROR: unsupported target '${TARGET}'"
    echo "Supported targets: local"
    exit 2
    ;;
esac

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1"
    exit 1
  }
}

echo "=== Cap deployment installer ==="
echo "Target: ${TARGET}"
echo "Repository: ${ROOT_DIR}"
echo

require_command kubectl
require_command helm
require_command docker
require_command openssl
require_command curl
require_command python3

echo "PREREQUISITES_OK"

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: Kubernetes cluster is not reachable."
  exit 1
fi

echo "KUBERNETES_REACHABLE"

if [[ ! -f "${ROOT_DIR}/secrets/local-values.yaml" ]]; then
  echo "ERROR: missing secrets/local-values.yaml"
  echo "Create the local secret values file before installation."
  exit 1
fi

echo "LOCAL_VALUES_PRESENT"

REGISTRY_HOST="${REGISTRY_HOST:-host.docker.internal}"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
REGISTRY="${REGISTRY_HOST}:${REGISTRY_PORT}"
REGISTRY_URL="https://${REGISTRY}"
REGISTRY_VERIFY_IP="${REGISTRY_VERIFY_IP:-127.0.0.1}"

REGISTRY_CERT_DIR="${ROOT_DIR}/environment/local-registry/certs"
REGISTRY_CA="${REGISTRY_CERT_DIR}/ca.crt"

EVIDENCE_DIR="${ROOT_DIR}/verification/logs"
EGRESS_EVIDENCE_DIR="${ROOT_DIR}/verification/egress"
GENERATED_DIR="${ROOT_DIR}/environment/customer-egress/generated"

mkdir -p "${EVIDENCE_DIR}" "${EGRESS_EVIDENCE_DIR}" "${GENERATED_DIR}"

echo
echo "=== Local registry ==="

REGISTRY_HOST="${REGISTRY_HOST}" \
  "${ROOT_DIR}/environment/local-registry/generate-certs.sh"

if [[ ! -f "${REGISTRY_CA}" ]]; then
  echo "ERROR: registry CA was not generated: ${REGISTRY_CA}"
  exit 1
fi

if docker ps -a \
  --filter "name=^cap-registry$" \
  --format '{{.Names}}' |
  grep -qx 'cap-registry'; then

  if docker ps \
    --filter "name=^cap-registry$" \
    --format '{{.Names}}' |
    grep -qx 'cap-registry'; then

    echo "REGISTRY_CONTAINER_RUNNING"

  else
    echo "Starting existing HTTPS registry..."
    docker start cap-registry >/dev/null
    echo "REGISTRY_CONTAINER_STARTED"
  fi

else
  echo "Creating HTTPS registry..."

  if ! docker image inspect registry:2 >/dev/null 2>&1; then
    echo "ERROR: required bootstrap image 'registry:2' is not available locally."
    echo "Preload registry:2 before running the constrained installer."
    exit 1
  fi

  docker run -d \
    --name cap-registry \
    -p "${REGISTRY_PORT}:5000" \
    -v "${REGISTRY_CERT_DIR}:/certs:ro" \
    -v cap-registry-data:/var/lib/registry \
    -e REGISTRY_HTTP_ADDR=0.0.0.0:5000 \
    -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
    -e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
    registry:2 >/dev/null

  echo "REGISTRY_CONTAINER_CREATED"
fi

echo "Waiting for HTTPS registry..."

registry_ready=false

for _ in $(seq 1 30); do
  if curl \
    --cacert "${REGISTRY_CA}" \
    --resolve "${REGISTRY}:${REGISTRY_VERIFY_IP}" \
    -fsS \
    "${REGISTRY_URL}/v2/" >/dev/null 2>&1; then

    registry_ready=true
    break
  fi

  sleep 1
done

if [[ "${registry_ready}" != true ]]; then
  echo "ERROR: HTTPS registry did not become ready."
  exit 1
fi

curl \
  --cacert "${REGISTRY_CA}" \
  --resolve "${REGISTRY}:${REGISTRY_VERIFY_IP}" \
  -fsS \
  "${REGISTRY_URL}/v2/" >/dev/null

echo "REGISTRY_TLS_OK"

echo
echo "=== Image promotion ==="

REGISTRY="${REGISTRY}" \
REGISTRY_SCHEME=https \
REGISTRY_CA="${REGISTRY_CA}" \
REGISTRY_VERIFY_IP="${REGISTRY_VERIFY_IP}" \
  "${ROOT_DIR}/scripts/promote-images-local-registry.sh"

echo "IMAGE_PROMOTION_OK"

echo
echo "=== Helm render validation ==="

RENDER_FILE="$(mktemp)"

cleanup_render() {
  rm -f "${RENDER_FILE}"
}

trap cleanup_render EXIT

helm template cap \
  "${ROOT_DIR}/helm/cap" \
  --namespace cap \
  -f "${ROOT_DIR}/secrets/local-values.yaml" \
  > "${RENDER_FILE}"

RENDERED_IMAGES="$(
  grep -E '^[[:space:]]*image: +[^[:space:]]+' "${RENDER_FILE}" |
    sed -E 's/^[[:space:]]*image: +//' |
    tr -d '"' |
    sed '/^[[:space:]]*$/d'
)"

IMAGE_COUNT="$(
  printf '%s\n' "${RENDERED_IMAGES}" |
    sed '/^[[:space:]]*$/d' |
    wc -l |
    tr -d ' '
)"

if [[ "${IMAGE_COUNT}" -eq 0 ]]; then
  echo "ERROR: no container images found in rendered workload."
  exit 1
fi

PINNED_COUNT="$(
  printf '%s\n' "${RENDERED_IMAGES}" |
    grep -Ec '@sha256:[0-9a-f]{64}$' || true
)"

if [[ "${IMAGE_COUNT}" -ne "${PINNED_COUNT}" ]]; then
  echo "ERROR: not every rendered container image is digest pinned."
  echo "IMAGE_COUNT=${IMAGE_COUNT}"
  echo "PINNED_COUNT=${PINNED_COUNT}"
  printf '%s\n' "${RENDERED_IMAGES}"
  exit 1
fi

NON_PRIVATE_IMAGES="$(
  printf '%s\n' "${RENDERED_IMAGES}" |
    awk -v prefix="${REGISTRY}/" '$0 !~ "^" prefix {print}' || true
)"

if [[ -n "${NON_PRIVATE_IMAGES}" ]]; then
  echo "ERROR: rendered workload contains an image outside the private registry:"
  echo "${NON_PRIVATE_IMAGES}"
  exit 1
fi

echo "HELM_IMAGES_PRIVATE_AND_DIGEST_PINNED"
echo "RENDERED_IMAGE_COUNT=${IMAGE_COUNT}"

rm -f "${RENDER_FILE}"
trap - EXIT

echo
echo "=== Customer egress CA ==="

"${ROOT_DIR}/environment/customer-egress/generate-ca.sh"

echo "CUSTOMER_EGRESS_CA_OK"

echo
echo "=== Customer egress verification PKI ==="

"${ROOT_DIR}/environment/customer-egress/test-ca/generate-certs.sh"

echo "EGRESS_TEST_PKI_OK"

echo
echo "=== Customer egress policy generation ==="

python3 "${ROOT_DIR}/scripts/generate-egress-allowlist.py"

if [[ ! -s "${GENERATED_DIR}/allowlist.txt" ]]; then
  echo "ERROR: generated egress allowlist is empty."
  exit 1
fi

echo "EGRESS_POLICY_GENERATED"

echo
echo "=== Namespaces ==="

kubectl create namespace customer-egress \
  --dry-run=client \
  -o yaml |
  kubectl apply -f -

kubectl create namespace cap \
  --dry-run=client \
  -o yaml |
  kubectl apply -f -

echo "NAMESPACES_READY"

echo
echo "=== Customer egress secrets ==="

kubectl -n customer-egress create secret generic customer-egress-ca \
  --from-file=mitmproxy-ca.pem="${ROOT_DIR}/environment/customer-egress/certs/mitmproxy-ca.pem" \
  --from-file=mitmproxy-ca-cert.pem="${ROOT_DIR}/environment/customer-egress/certs/mitmproxy-ca-cert.pem" \
  --dry-run=client \
  -o yaml |
  kubectl apply -f -

kubectl -n customer-egress create secret tls customer-egress-upstream-test-tls \
  --cert="${ROOT_DIR}/environment/customer-egress/test-ca/upstream-server.crt" \
  --key="${ROOT_DIR}/environment/customer-egress/test-ca/upstream-server.key" \
  --dry-run=client \
  -o yaml |
  kubectl apply -f -

kubectl -n customer-egress create secret generic customer-egress-upstream-ca \
  --from-file=upstream-ca.crt="${ROOT_DIR}/environment/customer-egress/test-ca/upstream-ca.crt" \
  --dry-run=client \
  -o yaml |
  kubectl apply -f -

kubectl -n cap create secret generic customer-egress-ca \
  --from-file=mitmproxy-ca-cert.pem="${ROOT_DIR}/environment/customer-egress/certs/mitmproxy-ca-cert.pem" \
  --dry-run=client \
  -o yaml |
  kubectl apply -f -

echo "EGRESS_SECRETS_OK"

echo
echo "=== Generated proxy configuration ==="

kubectl -n customer-egress create configmap customer-egress-proxy-config \
  --from-file=allowlist.txt="${GENERATED_DIR}/allowlist.txt" \
  --from-file=allowlist.py="${ROOT_DIR}/environment/customer-egress/allowlist.py" \
  --dry-run=client \
  -o yaml |
  kubectl apply -f -

echo "EGRESS_CONFIGMAP_OK"

echo
echo "=== Customer egress infrastructure ==="

kubectl apply \
  -f "${ROOT_DIR}/environment/customer-egress/manifests/test-server.yaml"

kubectl apply \
  -f "${ROOT_DIR}/environment/customer-egress/manifests/service.yaml"

kubectl apply \
  -f "${ROOT_DIR}/environment/customer-egress/manifests/network-policy.yaml"

kubectl apply \
  -f "${ROOT_DIR}/environment/customer-egress/manifests/deployment.yaml"

echo "EGRESS_INFRASTRUCTURE_APPLIED"

echo
echo "=== Restart egress components after generated state changes ==="

kubectl rollout restart \
  deployment/customer-egress-upstream-test \
  -n customer-egress >/dev/null

kubectl rollout status \
  deployment/customer-egress-upstream-test \
  -n customer-egress \
  --timeout=180s

kubectl rollout restart \
  deployment/customer-egress-proxy \
  -n customer-egress >/dev/null

kubectl rollout status \
  deployment/customer-egress-proxy \
  -n customer-egress \
  --timeout=180s

echo "EGRESS_COMPONENTS_RELOADED"

echo
echo "=== Cap network policy ==="

kubectl apply -f "${ROOT_DIR}/policies/network-policy-default-deny.yaml"
kubectl apply -f "${ROOT_DIR}/policies/network-policy-dns.yaml"
kubectl apply -f "${ROOT_DIR}/policies/network-policy-web-egress.yaml"
kubectl apply -f "${ROOT_DIR}/policies/network-policy-web-to-minio.yaml"
kubectl apply -f "${ROOT_DIR}/policies/network-policy-media-egress.yaml"
kubectl apply -f "${ROOT_DIR}/policies/network-policy-media-ingress.yaml"
kubectl apply -f "${ROOT_DIR}/policies/network-policy-media-to-web-ingress.yaml"
kubectl apply -f "${ROOT_DIR}/policies/network-policy-minio-setup-egress.yaml"
kubectl apply -f "${ROOT_DIR}/policies/network-policy-minio-setup-ingress.yaml"
kubectl apply -f "${ROOT_DIR}/policies/network-policy-mysql-ingress.yaml"
kubectl apply -f "${ROOT_DIR}/policies/network-policy-web-to-proxy.yaml"
kubectl apply -f "${ROOT_DIR}/policies/network-policy-media-to-proxy.yaml"

echo "NETWORK_POLICY_APPLY_OK"

echo
echo "=== Cap Helm release ==="

helm upgrade --install cap \
  "${ROOT_DIR}/helm/cap" \
  --namespace cap \
  --create-namespace \
  -f "${ROOT_DIR}/secrets/local-values.yaml" \
  --wait \
  --timeout 5m

echo "HELM_RELEASE_APPLY_OK"

echo
echo "=== Waiting for workloads ==="

kubectl -n cap rollout status deployment/cap-web --timeout=180s
kubectl -n cap rollout status deployment/cap-media-server --timeout=180s

kubectl -n customer-egress rollout status deployment/customer-egress-proxy --timeout=180s
kubectl -n customer-egress rollout status deployment/customer-egress-upstream-test --timeout=180s

echo "WORKLOAD_ROLLOUT_OK"

echo
echo "=== Private registry pull verification ==="

kubectl -n cap delete pod registry-pull-test \
  --ignore-not-found=true >/dev/null 2>&1 || true

PRIVATE_TEST_IMAGE="$(
  printf '%s\n' "${RENDERED_IMAGES:-}" |
    head -n 1
)"

if [[ -z "${PRIVATE_TEST_IMAGE}" ]]; then
  echo "ERROR: unable to determine private test image."
  exit 1
fi

kubectl -n cap run registry-pull-test \
  --image="${PRIVATE_TEST_IMAGE}" \
  --restart=Never \
  --command \
  -- sleep 30 >/dev/null

for _ in $(seq 1 60); do
  PHASE="$(
    kubectl get pod registry-pull-test \
      -n cap \
      -o jsonpath='{.status.phase}' \
      2>/dev/null || true
  )"

  case "${PHASE}" in
    Running|Succeeded)
      break
      ;;
    Failed)
      kubectl describe pod registry-pull-test -n cap || true
      kubectl delete pod registry-pull-test \
        -n cap \
        --ignore-not-found=true >/dev/null 2>&1 || true
      echo "ERROR: Kubernetes could not pull the private registry image."
      exit 1
      ;;
  esac

  sleep 2
done

FINAL_PHASE="$(
  kubectl get pod registry-pull-test \
    -n cap \
    -o jsonpath='{.status.phase}' \
    2>/dev/null || true
)"

if [[ "${FINAL_PHASE}" != "Running" &&
      "${FINAL_PHASE}" != "Succeeded" ]]; then

  kubectl describe pod registry-pull-test -n cap || true

  kubectl delete pod registry-pull-test \
    -n cap \
    --ignore-not-found=true >/dev/null 2>&1 || true

  echo "ERROR: private registry pull verification did not reach a healthy state."
  exit 1
fi

kubectl get pod registry-pull-test \
  -n cap \
  -o wide \
  > "${EVIDENCE_DIR}/private-registry-kubernetes-pull.txt"

kubectl delete pod registry-pull-test \
  -n cap \
  --ignore-not-found=true >/dev/null

echo "KUBERNETES_PRIVATE_REGISTRY_PULL_OK"

echo
echo "=== Application serving assertion ==="

APP_STATUS="$(
  kubectl exec -n cap deploy/cap-web -- \
    node -e '
      const http = require("http");

      const req = http.get("http://127.0.0.1:3000/", res => {
        console.log("HTTP_STATUS=" + res.statusCode);

        if (res.headers.location) {
          console.log("HTTP_LOCATION=" + res.headers.location);
        }

        res.resume();
      });

      req.on("error", err => {
        console.error("HTTP_ERROR=" + err.message);
        process.exit(1);
      });
    ' |
    tee "${EVIDENCE_DIR}/application-serving.txt" |
    awk -F= '/^HTTP_STATUS=/{print $2}'
)"

if [[ -z "${APP_STATUS}" ]]; then
  echo "ERROR: Cap Web did not return an HTTP status."
  exit 1
fi

if (( APP_STATUS < 200 || APP_STATUS >= 400 )); then
  echo "ERROR: Cap Web returned an unsuccessful HTTP status: ${APP_STATUS}"
  exit 1
fi

echo "APPLICATION_HTTP_STATUS=${APP_STATUS}"
echo "APPLICATION_SERVING_OK"

echo
echo "=== Installer-run proxy denial evidence ==="

DENIAL_FILE="${EGRESS_EVIDENCE_DIR}/install-run-proxy-denial.txt"
PROXY_LOG_FILE="${EGRESS_EVIDENCE_DIR}/install-run-proxy-denial-log.txt"

set +e

kubectl exec -n cap deploy/cap-web -- \
  node -e '
    const net = require("net");

    const proxyHost =
      "customer-egress-proxy.customer-egress.svc.cluster.local";
    const targetHost = "example.com";

    const s = net.connect(8080, proxyHost, () => {
      s.write(
        `CONNECT ${targetHost}:443 HTTP/1.1\r\n` +
        `Host: ${targetHost}:443\r\n` +
        `Connection: close\r\n\r\n`
      );
    });

    let response = "";

    s.on("data", d => {
      response += d.toString();

      if (response.includes("\r\n\r\n")) {
        process.stdout.write(response);

        if (/HTTP\/1\.1 403 Forbidden/i.test(response)) {
          process.exit(0);
        }

        process.exit(1);
      }
    });

    s.on("error", err => {
      console.error("CONNECT_ERROR=" + err.message);
      process.exit(1);
    });

    s.setTimeout(15000, () => {
      console.error("CONNECT_TIMEOUT");
      process.exit(1);
    });
  ' > "${DENIAL_FILE}" 2>&1

DENIAL_EXIT="$?"

kubectl logs \
  -n customer-egress \
  deployment/customer-egress-proxy \
  --tail=200 > "${PROXY_LOG_FILE}" 2>&1

set -e

if [[ "${DENIAL_EXIT}" -ne 0 ]]; then
  echo "ERROR: expected proxy denial was not observed."
  cat "${DENIAL_FILE}"
  exit 1
fi

if ! grep -Eq 'HTTP/1\.1 403 Forbidden' "${DENIAL_FILE}"; then
  echo "ERROR: denial response was not HTTP 403."
  cat "${DENIAL_FILE}"
  exit 1
fi

if ! grep -Eq 'EGRESS DENY CONNECT host=example\.com port=443' \
  "${PROXY_LOG_FILE}"; then
  echo "ERROR: proxy logs do not show the expected example.com denial."
  cat "${PROXY_LOG_FILE}"
  exit 1
fi

echo "INSTALL_RUN_PROXY_DENIAL_OK"

echo
echo "=== Full-deny proxy test ==="

EMPTY_ALLOWLIST="$(mktemp)"

: > "${EMPTY_ALLOWLIST}"

kubectl -n customer-egress create configmap customer-egress-proxy-config \
  --from-file=allowlist.txt="${EMPTY_ALLOWLIST}" \
  --from-file=allowlist.py="${ROOT_DIR}/environment/customer-egress/allowlist.py" \
  --dry-run=client \
  -o yaml |
  kubectl apply -f -

rm -f "${EMPTY_ALLOWLIST}"

kubectl rollout restart \
  deployment/customer-egress-proxy \
  -n customer-egress >/dev/null

kubectl rollout status \
  deployment/customer-egress-proxy \
  -n customer-egress \
  --timeout=180s

FULL_DENY_FILE="${EGRESS_EVIDENCE_DIR}/full-deny.txt"
FULL_DENY_LOG="${EGRESS_EVIDENCE_DIR}/full-deny-proxy-log.txt"
APP_DURING_FULL_DENY="${EGRESS_EVIDENCE_DIR}/full-deny-app-serving.txt"

set +e

kubectl exec -n cap deploy/cap-web -- \
  node -e '
    const net = require("net");

    const proxyHost =
      "customer-egress-proxy.customer-egress.svc.cluster.local";
    const targetHost =
      "egress-test.customer-egress.svc.cluster.local";

    const s = net.connect(8080, proxyHost, () => {
      s.write(
        `CONNECT ${targetHost}:8443 HTTP/1.1\r\n` +
        `Host: ${targetHost}:8443\r\n` +
        `Connection: close\r\n\r\n`
      );
    });

    let response = "";

    s.on("data", d => {
      response += d.toString();

      if (response.includes("\r\n\r\n")) {
        process.stdout.write(response);

        if (/HTTP\/1\.1 403 Forbidden/i.test(response)) {
          process.exit(0);
        }

        process.exit(1);
      }
    });

    s.on("error", err => {
      console.error("CONNECT_ERROR=" + err.message);
      process.exit(1);
    });

    s.setTimeout(15000, () => {
      console.error("CONNECT_TIMEOUT");
      process.exit(1);
    });
  ' > "${FULL_DENY_FILE}" 2>&1

FULL_DENY_EXIT="$?"

kubectl logs \
  -n customer-egress \
  deployment/customer-egress-proxy \
  --tail=200 > "${FULL_DENY_LOG}" 2>&1

set -e

if [[ "${FULL_DENY_EXIT}" -ne 0 ]]; then
  echo "ERROR: full-deny proxy test did not return HTTP 403."
  cat "${FULL_DENY_FILE}"
  exit 1
fi

if ! grep -Eq 'HTTP/1\.1 403 Forbidden' "${FULL_DENY_FILE}"; then
  echo "ERROR: full-deny proxy response was not HTTP 403."
  cat "${FULL_DENY_FILE}"
  exit 1
fi

APP_STATUS="$(
  kubectl exec -n cap deploy/cap-web -- \
    node -e '
      const http=require("http");

      const req=http.get("http://127.0.0.1:3000/",res=>{
        console.log(res.statusCode);
        res.resume();
      });

      req.on("error",e=>{
        console.error(e.message);
        process.exit(1);
      });
    '
)"

printf 'APP_HTTP_STATUS=%s\n' "${APP_STATUS}" \
  > "${APP_DURING_FULL_DENY}"

if (( APP_STATUS < 200 || APP_STATUS >= 400 )); then
  echo "ERROR: application stopped serving while external egress was fully denied."
  cat "${APP_DURING_FULL_DENY}"
  exit 1
fi

echo "FULL_DENY_EXTERNAL_EGRESS_OK"
echo "APP_REMAINS_SERVING_DURING_FULL_DENY"

echo
echo "=== Restore generated egress allowlist ==="

kubectl -n customer-egress create configmap customer-egress-proxy-config \
  --from-file=allowlist.txt="${GENERATED_DIR}/allowlist.txt" \
  --from-file=allowlist.py="${ROOT_DIR}/environment/customer-egress/allowlist.py" \
  --dry-run=client \
  -o yaml |
  kubectl apply -f -

kubectl rollout restart \
  deployment/customer-egress-proxy \
  -n customer-egress >/dev/null

kubectl rollout status \
  deployment/customer-egress-proxy \
  -n customer-egress \
  --timeout=180s

echo "EGRESS_ALLOWLIST_RESTORED"

echo
echo "=== Positive TLS interception verification ==="

POSITIVE_TLS_FILE="${EGRESS_EVIDENCE_DIR}/install-run-positive-tls-interception.txt"
POSITIVE_TLS_LOG="${EGRESS_EVIDENCE_DIR}/install-run-positive-tls-proxy-log.txt"

kubectl exec -n cap deploy/cap-web -- \
  node -e '
    const net = require("net");
    const tls = require("tls");
    const fs = require("fs");

    const proxyHost =
      "customer-egress-proxy.customer-egress.svc.cluster.local";
    const targetHost =
      "egress-test.customer-egress.svc.cluster.local";
    const targetPort = 8443;

    const s = net.connect(8080, proxyHost, () => {
      s.write(
        `CONNECT ${targetHost}:${targetPort} HTTP/1.1\r\n` +
        `Host: ${targetHost}:${targetPort}\r\n` +
        `Connection: close\r\n\r\n`
      );
    });

    let headers = "";

    s.on("data", d => {
      headers += d.toString();

      if (!headers.includes("\r\n\r\n")) {
        return;
      }

      console.log(headers.split("\r\n\r\n")[0]);

      const tlsSocket = tls.connect({
        socket: s,
        servername: targetHost,
        rejectUnauthorized: true,
        ca: fs.readFileSync("/etc/customer-egress-ca/ca.crt")
      }, () => {
        const peer = tlsSocket.getPeerCertificate();

        console.log("TLS_AUTHORIZED=" + tlsSocket.authorized);
        console.log("PEER_CN=" + peer.subject.CN);
        console.log("ISSUER_CN=" + peer.issuer.CN);

        tlsSocket.write(
          `GET / HTTP/1.1\r\n` +
          `Host: ${targetHost}:${targetPort}\r\n` +
          `Connection: close\r\n\r\n`
        );
      });

      tlsSocket.on("data", d => process.stdout.write(d));

      tlsSocket.on("error", err => {
        console.error("TLS_ERROR=" + err.message);
        process.exit(1);
      });
    });

    s.on("error", err => {
      console.error("CONNECT_ERROR=" + err.message);
      process.exit(1);
    });
  ' > "${POSITIVE_TLS_FILE}" 2>&1

kubectl logs \
  -n customer-egress \
  deployment/customer-egress-proxy \
  --tail=100 > "${POSITIVE_TLS_LOG}" 2>&1

if ! grep -q 'TLS_AUTHORIZED=true' "${POSITIVE_TLS_FILE}"; then
  echo "ERROR: positive TLS interception did not authorize."
  cat "${POSITIVE_TLS_FILE}"
  exit 1
fi

if ! grep -q 'ISSUER_CN=Zamp Customer Egress CA' "${POSITIVE_TLS_FILE}"; then
  echo "ERROR: positive TLS interception did not use the customer CA."
  cat "${POSITIVE_TLS_FILE}"
  exit 1
fi

if ! grep -q 'CUSTOMER_EGRESS_TLS_TEST_OK' "${POSITIVE_TLS_FILE}"; then
  echo "ERROR: controlled TLS endpoint did not return the expected response."
  cat "${POSITIVE_TLS_FILE}"
  exit 1
fi

if ! grep -Eq \
  'EGRESS ALLOW CONNECT host=egress-test\.customer-egress\.svc\.cluster\.local port=8443' \
  "${POSITIVE_TLS_LOG}"; then
  echo "ERROR: proxy did not log the expected positive CONNECT allow."
  cat "${POSITIVE_TLS_LOG}"
  exit 1
fi

echo "POSITIVE_TLS_INTERCEPTION_OK"

echo
echo "=== Final workload state ==="

kubectl get pods -n cap \
  | tee "${EVIDENCE_DIR}/install-final-cap-pods.txt"

kubectl get pods -n customer-egress \
  | tee "${EVIDENCE_DIR}/install-final-egress-pods.txt"

kubectl get networkpolicies -n cap \
  | tee "${EVIDENCE_DIR}/install-final-cap-networkpolicies.txt"

kubectl get networkpolicies -n customer-egress \
  | tee "${EVIDENCE_DIR}/install-final-egress-networkpolicies.txt"

kubectl get validatingadmissionpolicy cap-private-registry \
  -o yaml \
  > "${EVIDENCE_DIR}/install-final-admission-policy.yaml"

echo
echo "INSTALL_LOCAL_COMPLETE"