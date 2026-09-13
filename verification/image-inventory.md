# Image Inventory and Provenance Baseline

This inventory records the runtime artifacts identified from the upstream Cap
deployment and the immutable digests observed in the local environment.

| Component | Upstream reference | Registry | Digest observed | Artifact type | Customer-registry treatment |
|---|---|---|---|---|---|
| Cap Web | `ghcr.io/capsoftware/cap-web:latest` | GHCR | `sha256:8ee4cbd3fd87f88f538831aed06c954c525db9c2426a62abeaf0ca307c5e1ce9` | Runtime | Promote exact digest to private registry |
| Cap Media Server | `ghcr.io/capsoftware/cap-media-server:latest` | GHCR | `sha256:886ecc9b5684686410c691d13f94c678492b4ebaba3de0d295cdda63c64c04fe` | Runtime | Promote exact digest to private registry |
| MySQL | `mysql:8.0` | Docker Hub | `sha256:7dcddc01f13bab2f15cde676d44d01f61fc9f99fe7785e86196dfc07d358ae2b` | Runtime | Promote exact digest to private registry |
| MinIO | `quay.io/minio/minio:latest` | Quay | `sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e` | Runtime | Promote exact digest to private registry |
| MinIO MC | `quay.io/minio/mc:latest` | Quay | `sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727` | Runtime / init | Promote exact digest to private registry |

## Build bases identified from source

| Component | Dockerfile | Base image | Treatment |
|---|---|---|---|
| Cap Web | `apps/web/Dockerfile` | `oven/bun:1.4.0-alpine` | Build-time dependency; must be available to the controlled build environment |
| Cap Web | `apps/web/Dockerfile` | `node:24-alpine` | Build/runtime base used while building Cap Web |
| Cap Media Server | `apps/media-server/Dockerfile.standalone` | `oven/bun:1.4.0` | Build-time dependency; must be available to the controlled build environment |

## Verification boundary

The digests above establish the exact image artifacts observed locally at the
time of inventory creation. They are the identities to carry into the
customer-registry promotion process rather than relying on mutable `latest`
tags.

Independent signature/attestation verification has not yet been performed.
That remains an explicit supply-chain control to implement or document.
