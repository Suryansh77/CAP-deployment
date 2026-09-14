#!/usr/bin/env bash
set -Eeuo pipefail

REGISTRY="${REGISTRY:-host.docker.internal:5001}"
REGISTRY_SCHEME="${REGISTRY_SCHEME:-https}"
REGISTRY_CA="${REGISTRY_CA:-environment/local-registry/certs/ca.crt}"

# Host-side verification can resolve the canonical registry hostname to a
# local address without changing TLS hostname verification.
REGISTRY_VERIFY_IP="${REGISTRY_VERIFY_IP:-127.0.0.1}"

REGISTRY_URL="${REGISTRY_SCHEME}://${REGISTRY}"

LOG="verification/logs/private-registry-promotion.txt"

mkdir -p "$(dirname "$LOG")"

exec > >(tee "$LOG") 2>&1

echo "=== Private Registry Promotion ==="
date
echo "Registry: ${REGISTRY}"
echo "Scheme: ${REGISTRY_SCHEME}"
echo "CA: ${REGISTRY_CA}"
echo "Verification IP: ${REGISTRY_VERIFY_IP}"
echo

if [[ "${REGISTRY_SCHEME}" == "https" ]]; then
  [[ -f "${REGISTRY_CA}" ]] || {
    echo "ERROR: Registry CA not found: ${REGISTRY_CA}"
    exit 1
  }

  CURL_ARGS=(
    --cacert "${REGISTRY_CA}"
    --resolve "${REGISTRY}:${REGISTRY_VERIFY_IP}"
  )
else
  CURL_ARGS=()
fi

echo "Checking registry..."
curl -fsS \
  "${CURL_ARGS[@]}" \
  "${REGISTRY_URL}/v2/" \
  >/dev/null
echo "REGISTRY_OK"
echo

declare -a IMAGES=(
  "ghcr.io/capsoftware/cap-web:latest|cap/cap-web:latest"
  "ghcr.io/capsoftware/cap-media-server:latest|cap/cap-media-server:latest"
  "mysql:8.0|cap/mysql:8.0"
  "quay.io/minio/minio:latest|cap/minio:latest"
  "quay.io/minio/mc:latest|cap/minio-mc:latest"
)

for entry in "${IMAGES[@]}"; do
  IFS='|' read -r SOURCE TARGET <<< "${entry}"

  echo
  echo "=== ${SOURCE} -> ${REGISTRY}/${TARGET} ==="

  docker image inspect "${SOURCE}" >/dev/null
  echo "SOURCE_IMAGE_PRESENT"

  docker tag "${SOURCE}" "${REGISTRY}/${TARGET}"
  docker push "${REGISTRY}/${TARGET}"

  echo "PUBLISHED_DIGEST:"
  docker image inspect "${REGISTRY}/${TARGET}" \
    --format='local-image-id={{.Id}} local-repo-digests={{json .RepoDigests}}'

  echo "REGISTRY_MANIFEST:"

  REPO="${TARGET%:*}"
  TAG="${TARGET##*:}"

  curl -fsS \
    "${CURL_ARGS[@]}" \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
    "${REGISTRY_URL}/v2/${REPO}/manifests/${TAG}" \
    -o /tmp/cap-registry-manifest.json

  python3 - "${REGISTRY}" "${REPO}" "${TAG}" <<'PYVERIFY'
import json
import sys

registry, repo, tag = sys.argv[1:]

with open("/tmp/cap-registry-manifest.json", encoding="utf-8") as f:
    manifest = json.load(f)

print(f"registry={registry}")
print(f"repository={repo}")
print(f"tag={tag}")
print(f"mediaType={manifest.get('mediaType')}")
print(f"schemaVersion={manifest.get('schemaVersion')}")
print(f"configDigest={manifest.get('config', {}).get('digest')}")
print(f"layerCount={len(manifest.get('layers', []))}")

if manifest.get("schemaVersion") != 2:
    raise SystemExit("ERROR: registry manifest schemaVersion is not 2")

if not manifest.get("config", {}).get("digest"):
    raise SystemExit("ERROR: registry manifest has no config digest")

if not manifest.get("layers"):
    raise SystemExit("ERROR: registry manifest contains no layers")
PYVERIFY

  echo "REGISTRY_MANIFEST_OK"
done

echo
echo "=== Promotion complete ==="
