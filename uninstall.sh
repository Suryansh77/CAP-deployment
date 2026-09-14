#!/usr/bin/env bash
set -Eeuo pipefail

CAP_NAMESPACE="${CAP_NAMESPACE:-cap}"
EGRESS_NAMESPACE="${EGRESS_NAMESPACE:-customer-egress}"
RELEASE_NAME="${RELEASE_NAME:-cap}"

echo "==> Uninstalling Cap deployment"

echo "--> Helm release"
if helm status "${RELEASE_NAME}" -n "${CAP_NAMESPACE}" >/dev/null 2>&1; then
  helm uninstall "${RELEASE_NAME}" -n "${CAP_NAMESPACE}" --wait
else
  echo "Helm release ${RELEASE_NAME} not present; continuing"
fi

echo "--> Removing cluster-scoped admission controls"
kubectl delete validatingadmissionpolicy cap-private-registry \
  --ignore-not-found=true

kubectl delete validatingadmissionpolicybinding cap-private-registry \
  --ignore-not-found=true

echo "--> Removing customer egress environment"
kubectl delete namespace "${EGRESS_NAMESPACE}" \
  --ignore-not-found=true \
  --wait=true

echo "--> Removing Cap namespace"
kubectl delete namespace "${CAP_NAMESPACE}" \
  --ignore-not-found=true \
  --wait=true

echo "--> Verifying application namespaces are gone"
if kubectl get namespace "${CAP_NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: namespace ${CAP_NAMESPACE} still exists"
  exit 1
fi

if kubectl get namespace "${EGRESS_NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: namespace ${EGRESS_NAMESPACE} still exists"
  exit 1
fi

echo "--> Verifying cluster admission controls are gone"
if kubectl get validatingadmissionpolicy cap-private-registry >/dev/null 2>&1; then
  echo "ERROR: validatingadmissionpolicy cap-private-registry still exists"
  exit 1
fi

if kubectl get validatingadmissionpolicybinding cap-private-registry >/dev/null 2>&1; then
  echo "ERROR: validatingadmissionpolicybinding cap-private-registry still exists"
  exit 1
fi

echo "--> Verifying no Helm Cap release remains"
if helm list -A --filter '^cap$' | tail -n +2 | grep -q .; then
  echo "ERROR: Helm release cap still exists"
  exit 1
fi

echo "--> Verifying local registry remains available"
if docker inspect cap-registry >/dev/null 2>&1; then
  echo "Preserved bootstrap registry: cap-registry"
else
  echo "WARNING: cap-registry not found"
fi

echo
echo "UNINSTALL_COMPLETE"
