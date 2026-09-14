#!/usr/bin/env bash
set -Eeuo pipefail

CAP_NAMESPACE="${CAP_NAMESPACE:-cap}"
EGRESS_NAMESPACE="${EGRESS_NAMESPACE:-customer-egress}"
RELEASE_NAME="${RELEASE_NAME:-cap}"
EVIDENCE_DIR="${EVIDENCE_DIR:-verification/lifecycle/uninstall}"

mkdir -p "${EVIDENCE_DIR}"

log() {
  echo "[uninstall] $*"
}

fail() {
  echo "[uninstall][ERROR] $*" >&2
  exit 1
}

log "Starting uninstall at $(date)"
log "Cap namespace: ${CAP_NAMESPACE}"
log "Egress namespace: ${EGRESS_NAMESPACE}"
log "Helm release: ${RELEASE_NAME}"

{
  echo "=== UNINSTALL START ==="
  date

  echo
  echo "--- Helm release ---"
  helm status "${RELEASE_NAME}" -n "${CAP_NAMESPACE}" 2>&1 || true

  echo
  echo "--- Cap resources ---"
  kubectl get all,cm,secret,sa,role,rolebinding,networkpolicy,pvc,ingress \
    -n "${CAP_NAMESPACE}" 2>&1 || true

  echo
  echo "--- Customer egress resources ---"
  kubectl get all,cm,secret,sa,role,rolebinding,networkpolicy,pvc \
    -n "${EGRESS_NAMESPACE}" 2>&1 || true

  echo
  echo "--- Admission controls ---"
  kubectl get validatingadmissionpolicy cap-private-registry 2>&1 || true
  kubectl get validatingadmissionpolicybinding cap-private-registry 2>&1 || true

  echo
  echo "--- Relevant Helm releases ---"
  helm list -A
} > "${EVIDENCE_DIR}/before.txt"

log "Removing Helm release"
if helm status "${RELEASE_NAME}" -n "${CAP_NAMESPACE}" >/dev/null 2>&1; then
  helm uninstall "${RELEASE_NAME}" -n "${CAP_NAMESPACE}" --wait
else
  log "Helm release ${RELEASE_NAME} is already absent"
fi

log "Removing cluster-scoped admission controls"
kubectl delete validatingadmissionpolicy cap-private-registry \
  --ignore-not-found=true

kubectl delete validatingadmissionpolicybinding cap-private-registry \
  --ignore-not-found=true

log "Removing customer egress namespace"
kubectl delete namespace "${EGRESS_NAMESPACE}" \
  --ignore-not-found=true \
  --wait=true

log "Removing Cap namespace"
kubectl delete namespace "${CAP_NAMESPACE}" \
  --ignore-not-found=true \
  --wait=true

log "Verifying no installation namespaces remain"

if kubectl get namespace "${CAP_NAMESPACE}" >/dev/null 2>&1; then
  fail "Namespace ${CAP_NAMESPACE} still exists"
fi

if kubectl get namespace "${EGRESS_NAMESPACE}" >/dev/null 2>&1; then
  fail "Namespace ${EGRESS_NAMESPACE} still exists"
fi

log "Verifying cluster-scoped admission controls are gone"

if kubectl get validatingadmissionpolicy cap-private-registry >/dev/null 2>&1; then
  fail "ValidatingAdmissionPolicy cap-private-registry still exists"
fi

if kubectl get validatingadmissionpolicybinding cap-private-registry >/dev/null 2>&1; then
  fail "ValidatingAdmissionPolicyBinding cap-private-registry still exists"
fi

log "Verifying no Cap Helm release remains"

if helm list -A --filter '^cap$' --output json | jq -e '.[]' >/dev/null 2>&1; then
  fail "Helm release cap still exists"
fi

log "Verifying associated persistent volumes are gone"

for pvc_name in \
  minio-data-cap-minio-0 \
  mysql-data-cap-mysql-0
do
  if kubectl get pvc "${pvc_name}" -n "${CAP_NAMESPACE}" >/dev/null 2>&1; then
    fail "PVC ${pvc_name} still exists"
  fi
done

log "Verifying bootstrap registry remains intact"

if docker inspect cap-registry >/dev/null 2>&1; then
  REGISTRY_STATUS="$(docker inspect -f '{{.State.Status}}' cap-registry)"
  log "Preserved bootstrap registry: cap-registry (${REGISTRY_STATUS})"
else
  log "WARNING: cap-registry was not found"
fi

{
  echo "=== UNINSTALL COMPLETE ==="
  date

  echo
  echo "--- Namespaces ---"
  kubectl get namespace "${CAP_NAMESPACE}" 2>&1 || true
  kubectl get namespace "${EGRESS_NAMESPACE}" 2>&1 || true

  echo
  echo "--- Admission controls ---"
  kubectl get validatingadmissionpolicy cap-private-registry 2>&1 || true
  kubectl get validatingadmissionpolicybinding cap-private-registry 2>&1 || true

  echo
  echo "--- Helm release ---"
  helm list -A --filter '^cap$'

  echo
  echo "--- Remaining Cap/Egress namespaces ---"
  kubectl get namespace | grep -E "^(cap|customer-egress)[[:space:]]" || true

  echo
  echo "--- Bootstrap registry ---"
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' |
    grep -E '^cap-registry[[:space:]]' || true

  echo
  echo "RESULT=PASS"
} | tee "${EVIDENCE_DIR}/after.txt"

echo
echo "UNINSTALL_COMPLETE"
