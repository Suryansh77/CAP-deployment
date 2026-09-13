#!/usr/bin/env bash
set -Eeuo pipefail

REGISTRY="${REGISTRY:-localhost:5001}"
LOG="verification/logs/private-registry-promotion.txt"

mkdir -p "$(dirname "$LOG")"

exec > >(tee "$LOG") 2>&1

echo "=== Private Registry Promotion ==="
date
echo "Registry: $REGISTRY"
echo

echo "Checking registry..."
curl -fsS "http://${REGISTRY}/v2/" >/dev/null
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
  IFS='|' read -r SOURCE TARGET <<< "$entry"

  echo
  echo "=== $SOURCE -> $REGISTRY/$TARGET ==="

  docker image inspect "$SOURCE" >/dev/null
  echo "SOURCE_IMAGE_PRESENT"

  docker tag "$SOURCE" "$REGISTRY/$TARGET"
  docker push "$REGISTRY/$TARGET"

  echo "PUBLISHED_DIGEST:"
  docker image inspect "$REGISTRY/$TARGET" \
    --format='local-image-id={{.Id}} local-repo-digests={{json .RepoDigests}}'

  echo "REGISTRY_MANIFEST:"
  REPO="${TARGET%:*}"
  TAG="${TARGET##*:}"

  curl -fsS \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
    "http://${REGISTRY}/v2/${REPO}/manifests/${TAG}" \
    -o /tmp/cap-registry-manifest.json

  python3 - "$REGISTRY" "$REPO" "$TAG" <<'PYVERIFY'
import json
import sys

registry, repo, tag = sys.argv[1:]
with open("/tmp/cap-registry-manifest.json") as f:
    manifest = json.load(f)

print(f"registry={registry}")
print(f"repository={repo}")
print(f"tag={tag}")
print(f"mediaType={manifest.get('mediaType')}")
print(f"schemaVersion={manifest.get('schemaVersion')}")
print(f"configDigest={manifest.get('config', {}).get('digest')}")
print(f"layerCount={len(manifest.get('layers', []))}")
PYVERIFY

  echo "REGISTRY_MANIFEST_OK"
done

echo
echo "=== Promotion complete ==="
