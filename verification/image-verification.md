# Independent Image Verification

## Purpose

A customer reviewer should be able to verify the runtime image provenance
without trusting the Helm release output alone.

The deployed Cap workloads use images from the customer-controlled private
registry and reference immutable digests.

## Runtime image inventory

| Component | Private registry repository | Deployed reference |
|---|---|---|
| Web | `host.docker.internal:5001/cap/cap-web` | digest-pinned |
| Media server | `host.docker.internal:5001/cap/cap-media-server` | digest-pinned |
| MySQL | `host.docker.internal:5001/cap/mysql` | digest-pinned |
| MinIO | `host.docker.internal:5001/cap/minio` | digest-pinned |
| MinIO client | `host.docker.internal:5001/cap/minio-mc` | digest-pinned |
| Customer egress proxy | `host.docker.internal:5001/cap/mitmproxy` | digest-pinned |

## Independent verification procedure

First inspect the live Kubernetes workload image references:

    kubectl get deploy,statefulset -n cap -o json |
      jq -r '
        .items[] |
        .metadata.name as $name |
        .spec.template.spec.containers[] |
        "\($name)\t\(.name)\t\(.image)"
      '

Then inspect the customer egress proxy image:

    kubectl get deploy -n customer-egress -o json |
      jq -r '
        .items[] |
        .metadata.name as $name |
        .spec.template.spec.containers[] |
        "\($name)\t\(.name)\t\(.image)"
      '

Each runtime reference must:

1. use the approved private registry;
2. use a digest (`@sha256:...`);
3. correspond to a repository present in the customer registry.

The registry contents can then be independently inspected using the registry
API or an OCI-aware registry client.

Example registry endpoint:

    https://host.docker.internal:5001/v2/

The final registry verification evidence records successful HTTPS access and
a successful Kubernetes image pull from the private registry.

## Evidence

`verification/logs/private-registry-final-verification.txt`

This records the finalized HTTPS private-registry path and a successful
Kubernetes pull.

`verification/logs/private-registry-promotion.txt`

This records promotion of each runtime image and independent inspection of
the resulting registry manifest, including schema version, config digest,
and layer count.

`verification/image-inventory.md`

This records the complete discovered runtime image set and separates runtime
images from build, bootstrap, verification, developer, and other source
references.

## Important platform note

The local Apple Silicon environment promoted the available single-platform
image content. The promotion output explicitly reports when the source image
contained multiplatform content that was not completely present locally.

This is a property of the constrained local bootstrap and is not used as a
reason to remove digest pinning or private-registry enforcement.[C
