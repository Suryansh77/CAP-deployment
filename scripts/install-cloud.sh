#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-asia-south1}"
ZONE="${ZONE:-asia-south1-a}"
CLUSTER="${CLUSTER_NAME:-cap-gke-tf}"
REGISTRY="${REGISTRY:-${REGION}-docker.pkg.dev/${PROJECT_ID}/cap}"
REGISTRY_HOST="${REGISTRY%%/*}"

die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

for c in gcloud terraform kubectl helm docker openssl python3 curl; do need "$c"; done

echo "=== CAP CLOUD INSTALL ==="
echo "Project: ${PROJECT_ID}"
echo "Region: ${REGION}"
echo "Cluster: ${CLUSTER}"
echo "Registry: ${REGISTRY}"

export PATH="$HOME/.local/bin:$PATH"
gcloud config set project "${PROJECT_ID}" >/dev/null

echo "=== Terraform infrastructure ==="
terraform -chdir="${ROOT_DIR}/environment/gcp" init
terraform -chdir="${ROOT_DIR}/environment/gcp" apply -var="project_id=${PROJECT_ID}" -var="region=${REGION}" -var="zone=${ZONE}" -auto-approve

gcloud container clusters get-credentials "${CLUSTER}" --zone "${ZONE}" --project "${PROJECT_ID}"
echo "TERRAFORM_AND_CLUSTER_OK"

echo "=== Artifact Registry ==="
gcloud auth configure-docker "${REGISTRY_HOST}" --quiet

echo "=== Verify private runtime images ==="
docker pull "ghcr.io/capsoftware/cap-web@sha256:8ee4cbd3fd87f88f538831aed06c954c525db9c2426a62abeaf0ca307c5e1ce9"
docker tag "ghcr.io/capsoftware/cap-web@sha256:8ee4cbd3fd87f88f538831aed06c954c525db9c2426a62abeaf0ca307c5e1ce9" "${REGISTRY}/cap-web:latest"
docker push "${REGISTRY}/cap-web:latest"

docker pull "ghcr.io/capsoftware/cap-media-server@sha256:886ecc9b5684686410c691d13f94c678492b4ebaba3de0d295cdda63c64c04fe"
docker tag "ghcr.io/capsoftware/cap-media-server@sha256:886ecc9b5684686410c691d13f94c678492b4ebaba3de0d295cdda63c64c04fe" "${REGISTRY}/cap-media-server:latest"
docker push "${REGISTRY}/cap-media-server:latest"

docker pull "mysql@sha256:7dcddc01f13bab2f15cde676d44d01f61fc9f99fe7785e86196dfc07d358ae2b"
docker tag "mysql@sha256:7dcddc01f13bab2f15cde676d44d01f61fc9f99fe7785e86196dfc07d358ae2b" "${REGISTRY}/mysql:8.0"
docker push "${REGISTRY}/mysql:8.0"

docker pull "quay.io/minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e"
docker tag "quay.io/minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e" "${REGISTRY}/minio:latest"
docker push "${REGISTRY}/minio:latest"

docker pull "quay.io/minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727"
docker tag "quay.io/minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727" "${REGISTRY}/minio-mc:latest"
docker push "${REGISTRY}/minio-mc:latest"

docker pull "mitmproxy/mitmproxy@sha256:00b77b5d8804c8ad18cb6caefbf9d5849e895e8986c5ce011f4ae30f4385962f"
docker tag "mitmproxy/mitmproxy@sha256:00b77b5d8804c8ad18cb6caefbf9d5849e895e8986c5ce011f4ae30f4385962f" "${REGISTRY}/mitmproxy:latest"
docker push "${REGISTRY}/mitmproxy:latest"
echo "IMAGE_PROMOTION_OK"

echo "=== Resolve private digests ==="
WEB="$(gcloud artifacts docker images describe "${REGISTRY}/cap-web:latest" --format="value(image_summary.digest)")"
MEDIA="$(gcloud artifacts docker images describe "${REGISTRY}/cap-media-server:latest" --format="value(image_summary.digest)")"
MYSQL="$(gcloud artifacts docker images describe "${REGISTRY}/mysql:8.0" --format="value(image_summary.digest)")"
MINIO="$(gcloud artifacts docker images describe "${REGISTRY}/minio:latest" --format="value(image_summary.digest)")"
MC="$(gcloud artifacts docker images describe "${REGISTRY}/minio-mc:latest" --format="value(image_summary.digest)")"
PROXY="$(gcloud artifacts docker images describe "${REGISTRY}/mitmproxy:latest" --format="value(image_summary.digest)")"
printf "WEB=%s\nMEDIA=%s\nMYSQL=%s\nMINIO=%s\nMC=%s\nPROXY=%s\n" "$WEB" "$MEDIA" "$MYSQL" "$MINIO" "$MC" "$PROXY" | tee "${ROOT_DIR}/verification/logs/cloud-image-digests.txt"

echo "=== Customer egress PKI ==="
"${ROOT_DIR}/environment/customer-egress/generate-ca.sh"
"${ROOT_DIR}/environment/customer-egress/test-ca/generate-certs.sh"
python3 "${ROOT_DIR}/scripts/generate-egress-allowlist.py"

kubectl create namespace customer-egress --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace cap --dry-run=client -o yaml | kubectl apply -f -

kubectl -n customer-egress create secret generic customer-egress-ca --from-file=mitmproxy-ca.pem="${ROOT_DIR}/environment/customer-egress/certs/mitmproxy-ca.pem" --from-file=mitmproxy-ca-cert.pem="${ROOT_DIR}/environment/customer-egress/certs/mitmproxy-ca-cert.pem" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n customer-egress create secret tls customer-egress-upstream-test-tls --cert="${ROOT_DIR}/environment/customer-egress/test-ca/upstream-server.crt" --key="${ROOT_DIR}/environment/customer-egress/test-ca/upstream-server.key" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n customer-egress create secret generic customer-egress-upstream-ca --from-file=upstream-ca.crt="${ROOT_DIR}/environment/customer-egress/test-ca/upstream-ca.crt" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n cap create secret generic customer-egress-ca --from-file=mitmproxy-ca-cert.pem="${ROOT_DIR}/environment/customer-egress/certs/mitmproxy-ca-cert.pem" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n customer-egress create configmap customer-egress-proxy-config --from-file=allowlist.txt="${ROOT_DIR}/environment/customer-egress/generated/allowlist.txt" --from-file=allowlist.py="${ROOT_DIR}/environment/customer-egress/allowlist.py" --dry-run=client -o yaml | kubectl apply -f -

echo "=== Cloud egress manifests ==="
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}" "${VALUES_FILE:-}" "${TLS_DIR:-}"' EXIT
sed "s#host.docker.internal:5001/cap/mitmproxy@sha256:62d266a86ee95187217866c0e35487837498daa3aa1cdce37d256f07e198a47b#${REGISTRY}/mitmproxy@${PROXY}#g" "${ROOT_DIR}/environment/customer-egress/manifests/test-server.yaml" > "${TMP_DIR}/test-server.yaml"
sed "s#host.docker.internal:5001/cap/mitmproxy@sha256:62d266a86ee95187217866c0e35487837498daa3aa1cdce37d256f07e198a47b#${REGISTRY}/mitmproxy@${PROXY}#g" "${ROOT_DIR}/environment/customer-egress/manifests/deployment.yaml" > "${TMP_DIR}/deployment.yaml"
kubectl apply -f "${TMP_DIR}/test-server.yaml"
kubectl apply -f "${ROOT_DIR}/environment/customer-egress/manifests/service.yaml"
kubectl apply -f "${ROOT_DIR}/environment/customer-egress/manifests/network-policy.yaml"
kubectl apply -f "${TMP_DIR}/deployment.yaml"
kubectl rollout status deployment/customer-egress-upstream-test -n customer-egress --timeout=180s
kubectl rollout status deployment/customer-egress-proxy -n customer-egress --timeout=180s
echo "EGRESS_INFRASTRUCTURE_OK"

echo "=== Cap NetworkPolicies ==="
for f in "${ROOT_DIR}"/policies/network-policy-*.yaml; do kubectl apply -f "$f"; done
echo "NETWORK_POLICIES_OK"

echo "=== Cloud TLS ==="
TLS_DIR="$(mktemp -d)"
openssl req -x509 -nodes -newkey rsa:2048 -keyout "${TLS_DIR}/tls.key" -out "${TLS_DIR}/tls.crt" -days 365 -subj "/CN=cap.local" -addext "subjectAltName=DNS:cap.local" >/dev/null 2>&1
kubectl -n cap create secret tls cap-tls --cert="${TLS_DIR}/tls.crt" --key="${TLS_DIR}/tls.key" --dry-run=client -o yaml | kubectl apply -f -
echo "INGRESS_TLS_OK"

echo "=== Helm workload ==="
VALUES_FILE="$(mktemp)"
N="$(openssl rand -hex 32)"
D="$(openssl rand -hex 32)"
M="$(openssl rand -hex 32)"
P="$(openssl rand -hex 16)"
RP="$(openssl rand -hex 16)"
MP="$(openssl rand -hex 16)"
printf "%s\n" "secrets:" "  create: true" "  nextAuthSecret: ${N}" "  databaseEncryptionKey: ${D}" "  mediaServerWebhookSecret: ${M}" "  mysqlPassword: ${P}" "  mysqlRootPassword: ${RP}" "  minioRootUser: cap-admin" "  minioRootPassword: ${MP}" "  capAwsAccessKey: cap-admin" "  capAwsSecretKey: ${MP}" "  databaseUrl: mysql://cap:${P}@cap-mysql:3306/cap" "images:" "  web:
    repository: ${REGISTRY}/cap-web
    tag: latest
    digest: ${WEB}" "  mediaServer:
    repository: ${REGISTRY}/cap-media-server
    tag: latest
    digest: ${MEDIA}" "  mysql:
    repository: ${REGISTRY}/mysql
    tag: 8.0
    digest: ${MYSQL}" "  minio:
    repository: ${REGISTRY}/minio
    tag: latest
    digest: ${MINIO}" "  minioMc:
    repository: ${REGISTRY}/minio-mc
    tag: latest
    digest: ${MC}" "ingress:" "  enabled: true" "  className: gce" "  host: cap.local" "  tls:" "    enabled: true" "    secretName: cap-tls" "admission:" "  enabled: true" "  allowedImageRegistry: ${REGISTRY}/" > "${VALUES_FILE}"

helm template cap "${ROOT_DIR}/helm/cap" --namespace cap -f "${VALUES_FILE}" > "${TMP_DIR}/rendered.yaml"
grep -E "^[[:space:]]*image: " "${TMP_DIR}/rendered.yaml" | tee "${ROOT_DIR}/verification/logs/cloud-rendered-images.txt"
IMAGE_COUNT="$(grep -Ec "^[[:space:]]*image: " "${TMP_DIR}/rendered.yaml")"
PINNED_COUNT="$(grep -Ec "@sha256:[0-9a-f]{64}" "${TMP_DIR}/rendered.yaml" || true)"
PRIVATE_COUNT="$(grep -Ec "${REGISTRY}/[^[:space:]\\\"]+@sha256:[0-9a-f]{64}" "${TMP_DIR}/rendered.yaml" || true)"
[[ "${IMAGE_COUNT}" -eq "${PINNED_COUNT}" ]] || die "not all rendered images are digest pinned"
[[ "${IMAGE_COUNT}" -eq "${PRIVATE_COUNT}" ]] || die "not all rendered images use the private registry"
echo "HELM_RENDER_VALIDATION_OK"

helm upgrade --install cap "${ROOT_DIR}/helm/cap" --namespace cap --create-namespace -f "${VALUES_FILE}" --set-string config.capUrl=https://cap.local --wait --timeout 10m
echo "HELM_RELEASE_OK"

kubectl -n cap rollout status deployment/cap-web --timeout=300s
kubectl -n cap rollout status deployment/cap-media-server --timeout=300s
echo "WORKLOAD_ROLLOUT_OK"

echo "=== Application verification ==="
kubectl exec -n cap deploy/cap-web -- node -e 'const http=require("http");const r=http.get("http://127.0.0.1:3000/",x=>{console.log("HTTP_STATUS="+x.statusCode);x.resume();});r.on("error",e=>process.exit(1));' | tee "${ROOT_DIR}/verification/logs/cloud-application-serving.txt"
echo "APPLICATION_SERVING_OK"

echo "=== Proxy denial verification ==="
set +e
kubectl exec -n cap deploy/cap-web -- node -e 'const net=require("net");const s=net.connect(8080,"customer-egress-proxy.customer-egress.svc.cluster.local",()=>s.write("CONNECT example.com:443 HTTP/1.1\\r\\nHost: example.com:443\\r\\nConnection: close\\r\\n\\r\\n"));let r="";s.on("data",d=>{r+=d;if(r.includes("\\r\\n\\r\\n")){process.stdout.write(r);process.exit(/HTTP\\/1\\.1 403 Forbidden/i.test(r)?0:1)}});s.on("error",()=>process.exit(1));s.setTimeout(15000,()=>process.exit(1));' > "${ROOT_DIR}/verification/egress/cloud-proxy-denial.txt" 2>&1
DENIAL_EXIT="$?"
set -e
kubectl logs -n customer-egress deployment/customer-egress-proxy --tail=200 > "${ROOT_DIR}/verification/egress/cloud-proxy-denial-log.txt"
[[ "${DENIAL_EXIT}" -eq 0 ]] || die "proxy denial test failed"
grep -Eq "HTTP/1\\.1 403 Forbidden" "${ROOT_DIR}/verification/egress/cloud-proxy-denial.txt" || die "expected HTTP 403 not observed"
grep -Eq "EGRESS DENY CONNECT host=example\\.com port=443" "${ROOT_DIR}/verification/egress/cloud-proxy-denial-log.txt" || die "proxy denial log missing"
echo "PROXY_DENIAL_OK"

echo "=== Final state ==="
kubectl get pods -n cap | tee "${ROOT_DIR}/verification/logs/cloud-final-cap-pods.txt"
kubectl get pods -n customer-egress | tee "${ROOT_DIR}/verification/logs/cloud-final-egress-pods.txt"
kubectl get networkpolicies -n cap | tee "${ROOT_DIR}/verification/logs/cloud-final-cap-networkpolicies.txt"
kubectl get networkpolicies -n customer-egress | tee "${ROOT_DIR}/verification/logs/cloud-final-egress-networkpolicies.txt"
kubectl get validatingadmissionpolicy cap-private-registry -o yaml > "${ROOT_DIR}/verification/logs/cloud-final-admission-policy.yaml"
kubectl get ingress -n cap -o wide | tee "${ROOT_DIR}/verification/logs/cloud-ingress.txt"
echo "CLOUD_INSTALL_COMPLETE"
