# Image Inventory

This inventory separates customer runtime images from build, bootstrap,
verification, developer, CI, and cluster-system images.

## Customer runtime images

| Component | Source image | Deployed image | Purpose | Supply-chain treatment |
|---|---|---|---|---|
| Web | `ghcr.io/capsoftware/cap-web:latest` | Private registry, digest pinned | Next.js application | Promoted to private registry; digest pinned |
| Media server | `ghcr.io/capsoftware/cap-media-server:latest` | Private registry, digest pinned | FFmpeg/media processing | Promoted to private registry; digest pinned |
| MySQL | `mysql:8.0` | Private registry, digest pinned | Application database | Promoted to private registry; digest pinned |
| MinIO | `minio/minio:latest` | Private registry, digest pinned | S3-compatible object storage | Promoted to private registry; digest pinned |
| MinIO client | `minio/mc:latest` | Private registry, digest pinned | Bucket initialization hook | Promoted to private registry; digest pinned |
| Customer egress proxy | `mitmproxy/mitmproxy` | Private registry, digest pinned | Customer-controlled TLS-intercepting egress proxy | Promoted to private registry; digest pinned |

## Build-stage images

| Image | Source | Runtime? | Notes |
|---|---|---:|---|
| `oven/bun:1.4.0-alpine` | `apps/web/Dockerfile` | No | Web build stage |
| `node:24-alpine` | `apps/web/Dockerfile` | No | Web base/runtime build image; deployed web image is prebuilt |
| `oven/bun:1.4.0` | Media Dockerfiles | No | Media-server build stage |

These images must be available to whatever trusted build/promotion environment
produces the customer runtime artifacts, but they are not customer-cluster
runtime dependencies.

## Bootstrap images

| Image | Runtime? | Notes |
|---|---:|---|
| `registry:2` | No | Local HTTPS private-registry bootstrap only |

The bootstrap registry is intentionally outside the customer application
runtime image set.

## Verification / test images

Verification images are used only to test admission, egress, TLS interception,
or deployment behavior. They are not part of the application runtime supply
chain.

## Developer / observability images

| Image | Runtime? | Notes |
|---|---:|---|
| `docker.io/grafana/otel-lgtm` | No | Local development/observability tooling |

## Other source references

The source repository also contains references such as
`bitnami/minio:latest` in `docker-compose.template.yml` and dynamically
generated GHCR images in CI workflows.

These were discovered during the repository sweep but are not used by the
customer Kubernetes runtime.

## Live cluster verification

The local deployment was inspected directly with Kubernetes and showed:

- All Cap application images use the private registry.
- All deployed Cap images are digest-pinned.
- The customer egress proxy image is also private and digest-pinned.
- Rancher/K3s images are platform infrastructure rather than Cap application
  supply-chain dependencies.

Live image evidence is archived separately with the installation and
verification logs.
