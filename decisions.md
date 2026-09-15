# Engineering Decisions

This document records material implementation decisions, rejected alternatives,

trade-offs, failures that changed the design, and deliberately cut scope.

## 1. Overall approach

### Decision

Build the solution around a namespace-scoped Helm deployment of Cap with

customer-like security controls enforced outside the application itself.

### Chosen

- Helm for workload deployment.

- Kubernetes NetworkPolicy for default-deny and explicit east-west traffic.

- Namespace-scoped resources; no cluster-admin dependency.

- Immutable image references using digests.

- Private-registry-only deployment model.

- Evidence captured under `verification/`.

- Environment-specific bootstrap kept separate from portable workload manifests.

### Rejected

Modifying the upstream Cap application to satisfy infrastructure requirements.

### Reason

The assignment explicitly treats Cap as the workload and expects the candidate

to solve deployment/security/environment constraints around it.

---

## 2. Local Kubernetes environment

### Decision

Use Rancher Desktop Kubernetes as the local customer-like environment.

### Chosen

- Rancher Desktop

- Kubernetes v1.36.4

- Local storage class `local-path`

- Traefik ingress

- Moby/Docker container engine

### Trade-off

This is a reproducible constrained local environment rather than a production

shared cluster. Storage and ingress behavior are therefore documented as

local-environment approximations.

---

## 3. Container runtime choice

### Decision

Keep Moby/Docker for the current local environment.

### Why

The environment was already configured and the Kubernetes cluster and Cap

deployment were working. Switching runtimes after implementation would

invalidate access to the current runtime's image store and introduce avoidable

environment churn.

### Rejected

Switching the entire local environment from Moby/Docker to containerd

mid-implementation.

### Important trade-off

Moby-specific registry configuration must remain isolated to the local

environment bootstrap. The Helm workload itself must remain runtime-neutral and

must not depend on Moby.

### Correction

The initial recommendation to prefer Moby was too strong. The assignment does

not require Moby, and a more portable decision would have explicitly separated

local container-engine choice from the customer deployment architecture.

---

## 4. Helm namespace handling

### Decision

Do not create the application namespace inside the Helm chart.

### Chosen

Use:

`helm install ... --namespace cap --create-namespace`

### Reason

The assignment targets a shared cluster with namespace-scoped access. Keeping

namespace lifecycle outside the workload chart avoids implying cluster-wide

namespace-management privileges are required by the release.

---

## 5. Runtime security context

### Decision

Explicitly set numeric non-root UID/GID for Cap Web and Media Server.

### Problem encountered

Kubernetes rejected:

- Cap Web because the image used a named user (`nextjs`) that could not be

statically verified as numeric non-root.

- Media Server because its image ran as root.

### Resolution

Set explicit:

- `runAsUser: 1001`

- `runAsGroup: 1001`

- `runAsNonRoot: true`

for those workloads.

### Evidence

The original failure and remediation were tested during deployment and recorded

in the implementation history.

---

## 6. NetworkPolicy model

### Decision

Use namespace-wide default-deny ingress/egress and explicitly allow only

required application paths.

### Allowed paths

- DNS

- Web -> MySQL

- Web -> MinIO

- Web -> Media Server

- Media Server -> Web

- MinIO setup Job -> MinIO

### Rejected

Broad namespace-wide allow rules.

### Reason

The customer requirement is least-privilege egress/communication and a

default-deny posture.

---

## 7. NetworkPolicy naming

### Decision

Use separate Kubernetes NetworkPolicy objects for directional ingress and

egress where both are needed.

### Failure encountered

An ingress and egress policy were initially created with the same Kubernetes

object name. Applying the second object replaced the first object because

NetworkPolicy identity is namespace + name.

### Symptom

Media Server -> Web communication failed even though the intended policy

appeared to have been applied.

### Resolution

Use unique policy names, including:

`allow-media-server-to-web`

and

`allow-media-server-to-web-ingress`

### Lesson

NetworkPolicy direction is independent and object names must be unique when

separate policy objects are required.

### Evidence

`verification/logs/networkpolicy-media-to-web-incident.txt`

---

## 8. External S3 egress

### Decision

Do not allow public AWS S3 egress in the baseline self-hosted deployment.

### Evidence

Cap supports configurable/default AWS S3 endpoints, but the deployed

self-hosted environment uses internal MinIO. A public S3 request was blocked,

while internal MinIO returned HTTP 200.

### Classification

Not required for baseline.

### Decision

BLOCK `s3.amazonaws.com:443`.

### Replacement

Internal MinIO service.

### Evidence

`verification/logs/s3-egress-investigation.txt`

---

## 9. Tinybird analytics

### Decision

Do not allow external Tinybird egress in the baseline.

### Evidence

Tinybird integration exists in source, but the deployed Cap Web container

has no Tinybird host or token configured.

### Classification

Optional / disabled.

### Decision

BLOCK; no external Tinybird hostname in baseline allowlist.

### Evidence

`verification/logs/tinybird-egress-investigation.txt`

---

## 10. cap.so / Vercel Firewall

### Decision

Do not allow baseline egress to `cap.so` or `api.vercel.com`.

### Evidence

Cap contains optional Vercel Firewall/rate-limiting and Vercel-specific

domain-management integrations. The self-hosted deployment tolerates their

absence.

### Classification

Optional vendor functionality.

### Decision

BLOCK for the baseline.

### Evidence

`verification/logs/cap-so-vercel-investigation.txt`

---

## 11. Sentry / OpenTelemetry

### Decision

Do not allow baseline external Sentry or OTLP telemetry egress.

### Evidence

OpenTelemetry tracing code exists, but the inspected code does not establish

an external exporter endpoint. The deployed workload has no SENTRY_DSN or OTLP

exporter endpoints configured.

### Classification

Optional / non-required telemetry.

### Decision

BLOCK; no external telemetry destination added to the baseline allowlist.

### Evidence

`verification/logs/sentry-otel-egress-investigation.txt`

---

## 12. Image provenance model

### Decision

Use immutable image digests rather than relying on mutable `latest` tags.

### Runtime artifacts identified

- Cap Web

- Cap Media Server

- MySQL

- MinIO

- MinIO MC setup image

### Build bases identified

- `oven/bun:1.4.0-alpine`

- `node:24-alpine`

- `oven/bun:1.4.0`

### Reason

The customer requires private-registry-only images and the assignment

explicitly requires finding every image and independently verifying supply

chain artifacts.

### Evidence

`verification/image-inventory.md`

---

## 13. Private registry

### Decision

Build a local private registry to reproduce the customer requirement.

### Chosen

Local Docker Registry exposed at:

`localhost:5001`

Kubernetes reaches it through:

`host.docker.internal:5001`

### Evidence

The registry API returned five repositories corresponding to the five runtime

artifacts.

### Important limitation

The local registry was populated from the single local Apple Silicon platform

available in the current environment. Docker reported that not all upstream

multi-platform content was present.

Therefore the implementation must not claim that the entire upstream

multi-platform manifest was preserved.

---

## 14. Registry promotion

### Decision

Promote exact observed source artifacts into the private registry rather than

rebuilding unrelated substitutes.

### Runtime artifacts promoted

- Cap Web

- Cap Media Server

- MySQL

- MinIO

- MinIO MC

### Verification

Each private-registry repository returned a valid OCI or Docker v2 manifest.

### Evidence

`verification/logs/private-registry-promotion.txt`

and registry verification performed during implementation.

---

## 15. Helm image references

### Decision

Make Helm support:

`repository@sha256:digest`

while retaining tag support for environments that do not provide a digest.

### Reason

This allows the same chart to target different customer registries without

hard-coding a specific registry vendor.

### Rejected

Hard-coding public GHCR/Docker Hub/Quay references into deployment templates.

### Verification

Rendered manifests showed all five runtime images using the private registry

and immutable digests.

---

## 16. MinIO initialization

### Decision

Represent the upstream MinIO bucket initialization as a Helm hook Job.

### Chosen

`post-install,post-upgrade`

### Reason

The MinIO StatefulSet should exist and become ready before bucket

initialization is attempted.

### Security

The setup Job uses:

- private-registry `mc` image

- immutable digest

- non-root security context

- disabled service-account token automount

- only MinIO network access

### Network policy

Dedicated ingress and egress policies allow only:

`minio-setup -> minio:9000`

---

## 17. Private registry Kubernetes pull failure

### Test

Attempted to pull:

`host.docker.internal:5001/cap/mysql:8.0`

from the `cap` namespace.

### Result

`ErrImagePull` followed by `ImagePullBackOff`.

### Exact failure

The Kubernetes runtime attempted:

`https://host.docker.internal:5001/...`

while the local registry was serving HTTP.

Error:

`http: server gave HTTP response to HTTPS client`

### Diagnosis

TCP/network reachability was working, but registry transport configuration

was not.

### Evidence

`verification/logs/private-registry-pull-failure.txt`

### Remediation attempted

Rancher Desktop provisioning was used to install a K3s registry configuration

pointing `host.docker.internal:5001` to HTTP.

### Result

The registry configuration was successfully provisioned, but the Kubernetes

node is using the Moby/Docker runtime, and the image pull still attempted HTTPS.

### Conclusion

The K3s `registries.yaml` configuration alone does not control this Moby-based

image-pull path.

### Security implication

The local HTTP registry is a customer-like test mechanism only. The intended

regulated-customer architecture should use TLS for the private registry.

---

## 18. Moby-specific registry configuration

### Decision status

Not considered part of the portable workload architecture.

### Current environment

Rancher Desktop:

- version `v1.24.0`

- Moby/Docker server `29.5.3`

### Current bootstrap

`override.yaml` provisions:

`/etc/rancher/k3s/registries.yaml`

for the local HTTP registry.

### Important limitation

This successfully provisions the K3s registry configuration but does not solve

the Moby image-pull HTTPS behavior observed in the current environment.

### Follow-up

Either:

1. configure the Moby runtime specifically for the local test registry, or

2. use an HTTPS local registry with a trusted CA, which better matches the

customer's regulated/TLS-intercepted environment.

No Moby-specific configuration should be required by the final Helm workload.

---

## 20. Private registry TLS remediation

### Problem

The initial Kubernetes pull from the local private registry failed because

the Moby runtime attempted HTTPS while the registry served HTTP.

### Decision

Use HTTPS for the local customer-like private registry rather than relying

on an insecure-registry exception.

### Implementation

- Created a local customer-like Halden Pharma CA.

- Issued a registry certificate for `host.docker.internal`.

- Recreated the registry using the existing persistent registry volume.

- Configured the registry to serve HTTPS.

- Provisioned the public CA certificate into the Moby registry trust path.

- Kept the CA private key on the host and out of the runtime.

### Verification

The same Kubernetes image-pull test subsequently succeeded:

`PRIVATE_REGISTRY_PULL_OK`

Pod status:

`Running`, `1/1`

### Rejected

Continuing with a plain HTTP registry plus an insecure-registry exception as the

final architecture.

### Reason

HTTPS better models the regulated customer environment and provides a proper

certificate trust boundary. The final workload architecture remains

runtime-neutral.

### Evidence

- `verification/logs/private-registry-pull-failure.txt`

- `verification/logs/private-registry-pull-success.txt`

---

## 21. Namespace-scoped RBAC

### Decision

Use a separate `cap-deployer` ServiceAccount bound to a namespaced

`cap-deployer` Role and RoleBinding.

Cap application workloads continue using the `cap` ServiceAccount with

`automountServiceAccountToken: false`.

### Why

The customer provides a namespace on a shared cluster and explicitly does not

grant cluster-admin access to the FDE.

The deployment therefore cannot depend on cluster-scoped permissions.

Separating the deployment identity from the application identity also ensures

that the application does not inherit deployment privileges that it does not

need.

### Permission model

The deployment identity can manage only the resource types required by the Cap

Helm release inside the application namespace.

Read-only Pod and Event permissions and Pod log access are included for

namespace-scoped verification and troubleshooting.

No cluster-scoped permissions are granted.

### Alternatives rejected

Using the built-in `edit` or `admin` ClusterRole was rejected because those

permissions are broader than necessary and would violate the intended

least-privilege model.

Granting deployment privileges to the application ServiceAccount was rejected

because the Cap application has no requirement to access the Kubernetes API.

### Verification

The following were verified:

- Role and RoleBinding exist in the `cap` namespace.

- The rendered chart contains no ClusterRole or ClusterRoleBinding.

- Required namespace operations return `yes`.

- Cluster-scoped operations return `no`.

- Cross-namespace operations return `no`.

- Application ServiceAccount token automount is disabled.

- Application ServiceAccount cannot access the tested Kubernetes resources.

Evidence:

`verification/logs/rbac-verification.txt`

---

## 22. MinIO Setup Hook Remediation

### Problem

The hardened MinIO setup Job initially failed because the non-root `mc`

process attempted to create its configuration directory under `/.mc`.

### Decision

Keep the Job non-root and provide it with a writable temporary HOME:

`HOME=/tmp`

A second failure then exposed incorrect use of `mc ready` with a raw endpoint.

### Root cause

`mc ready` requires a configured `mc` target/alias.

### Final implementation

The hook now performs:

1. `mc alias set capminio`

2. `mc ready capminio`

3. `mc mb capminio/cap --ignore-existing`

### Verification

The corrected command sequence was manually validated from the running hook

pod.

The subsequent Helm upgrade completed successfully as revision 8.

### Security tradeoff

No security control was relaxed.

The Job remains:

- non-root

- `runAsNonRoot: true`

- `allowPrivilegeEscalation: false`

- all capabilities dropped

- `RuntimeDefault` seccomp

- ServiceAccount token automount disabled

### Evidence

- `verification/logs/minio-setup-hook-failure.txt`

- Helm history showing failed upgrade and rollback

- successful Helm revision 8
## 23. Admission Control

### Decision

Use Kubernetes-native `ValidatingAdmissionPolicy` and
`ValidatingAdmissionPolicyBinding` to enforce the private-registry invariant in
the Cap namespace.

### Why

The local Kubernetes environment exposes the `admissionregistration.k8s.io/v1`
ValidatingAdmissionPolicy API. Using the built-in policy mechanism avoids introducing
another admission-controller deployment and therefore avoids another runtime image,
another supply-chain dependency, and another controller lifecycle.

The policy is scoped to the Cap namespace through the namespace selector.

### Security invariant

Any Pod admitted into the Cap namespace must use an image beginning with:

`host.docker.internal:5001/`

The validation covers:

- `spec.containers`

- `spec.initContainers`

- `spec.ephemeralContainers`

This prevents a non-compliant init or ephemeral container from bypassing the
main-container image restriction.

### Enforcement

The policy uses:

`failurePolicy: Fail`

The binding uses:

`validationActions: [Deny]`

The live policy was observed at generation 2 with no CEL expression warnings.

### Implementation issue and correction

The first implementation attempted to concatenate the typed Pod container lists with
CEL `+`.

The Kubernetes API reported a type-checking warning because the required list
addition overload was not available for those typed fields.

The expression was redesigned to validate the three container collections
independently.

The corrected policy passed the server-side Helm dry run with no expression warnings.

### Verification

Public main-container image

Attempted image:

`busybox:1.36`

Result:

The API server rejected the Pod with:

`Error from server (Forbidden)`

The error explicitly identified `cap-private-registry` and the approved-registry
requirement.

A subsequent lookup returned `NotFound`, confirming that the rejected Pod was not
created.

Approved private image

Attempted image:

`host.docker.internal:5001/cap/minio-mc@sha256:37d109dddbbb2c95873f5fc81ac93f37023264770fc580a7564148892087b1b7`

Result:

`pod/admission-private-test created`

The container subsequently entered `Error`, but the Pod creation proves that the
admission request itself was accepted.

Public init-container bypass

A test Pod used a compliant private-registry main container and a public
`busybox:1.36` init container.

Result:

The API server rejected the Pod with `Forbidden`.

A subsequent Pod lookup returned `NotFound`.

This proves that a public init-container image cannot bypass the registry restriction.

### Live verification

The corrected policy was successfully installed as Helm revision 10.

The Kubernetes API reported:

`observedGeneration=2`

The binding reported:

`validationActions=["Deny"]`

The expression-warning field returned no warnings.

### Evidence

`verification/logs/admission-control-verification.txt`

### Status

Complete for the current local target.

---

---

## 23. Customer Egress Proxy Architecture

### Decision

Implement customer-style outbound egress as infrastructure outside the Cap Helm workload.

### Chosen

- A dedicated `customer-egress` namespace hosts the egress proxy.
- Cap Web and Media Server receive HTTP/HTTPS proxy environment variables through Helm values.
- The Cap namespace uses NetworkPolicy to permit application traffic to the proxy on TCP/8080.
- Direct external traffic from Cap remains blocked by the namespace default-deny egress policy.
- The proxy enforces an explicit L7 destination allowlist.
- TLS interception is enabled at the proxy and client workloads trust the customer egress CA.
- The Cap Helm chart remains environment-neutral; proxy endpoints and CA configuration are supplied as environment values.

### Rejected

Using the host machine's corporate proxy or Cisco Secure Access CA as part of the deployment architecture.

### Reason

The host's outbound interception is environment-specific and is not representative of a customer-controlled deployment. The customer requirement is a customer-owned proxy and customer CA, so the implementation must reproduce that boundary independently.

### Security model

The proxy is not treated as the sole security boundary.

NetworkPolicy prevents Cap workloads from bypassing the proxy for direct Internet access, while the proxy allowlist controls which destinations may be reached through the permitted egress path.

---

## 24. Customer Egress TLS Interception

### Decision

Use a customer-style CA generated for the local verification environment and require client-side certificate validation.

### Chosen

The Cap Web workload trusts:

`Zamp Customer Egress CA`

The proxy terminates client TLS and generates a destination certificate signed by that CA. Upstream TLS verification remains enabled.

### Problem encountered

The first verification upstream CA was X.509 Version 1 and did not contain the CA extensions required by the container's Python/OpenSSL validation path.

### Resolution

The verification PKI generation was replaced with X.509 v3 CA and server certificates including:

- critical CA/basic constraints
- key usage
- subject key identifier
- authority key identifier
- server extended key usage
- subject alternative names

The corrected upstream certificate successfully validates in the proxy container.

### Evidence

The corrected direct upstream verification returned:

`STATUS= 200`

`CUSTOMER_EGRESS_TLS_TEST_OK`

---

## 25. Customer Egress Enforcement Verification

### Positive verification

The real `cap-web` workload successfully connected through the customer egress proxy to the controlled HTTPS verification endpoint.

Observed:

- `HTTP/1.1 200 Connection established`
- `TLS_AUTHORIZED=true`
- certificate issuer:
  `O=Zamp Customer, OU=Egress Security, CN=Zamp Customer Egress CA`
- upstream response:
  `CUSTOMER_EGRESS_TLS_TEST_OK`

This proves the client trusted a proxy-issued certificate rather than bypassing TLS interception.

### Negative verification

An unallowlisted external destination, `example.com:443`, was rejected by the proxy with:

`HTTP/1.1 403 Forbidden`

The proxy recorded:

`EGRESS DENY CONNECT host=example.com port=443`

A second test removed all HTTP/HTTPS proxy environment variables from the Cap Web process. Direct access to `example.com:443` failed with connection refused.

### Conclusion

Both enforcement layers are independently demonstrated:

1. The proxy blocks destinations outside the explicit allowlist.
2. Cap workloads cannot bypass the proxy through direct Internet connectivity.

Evidence is retained under:

`verification/egress/`

---

## 26. Verification-Only Egress Destination

### Decision

The controlled HTTPS endpoint used to validate TLS interception is a verification dependency, not a permanent application runtime dependency.

### Reason

The baseline self-hosted Cap deployment uses internal MinIO and does not currently require external runtime egress. Adding an external destination solely to make the proxy appear functional would weaken the evidence-derived allowlist model.

### Final intent

The verification destination must remain explicitly classified as `phase: verification` and must not become part of the permanent production allowlist.

The permanent runtime allowlist will contain only destinations justified by observed application behavior or an explicit customer requirement.

---

## 27. Policy as Source of Truth

### Decision

The repository policy file is the authoritative source for customer egress requirements.

### Chosen

`policies/egress-allowlist.yaml`

Each future entry must identify:

- FQDN
- port
- component
- reason
- what breaks without access
- installation-time versus permanent use

The proxy configuration should be generated from this policy rather than maintaining a second independently edited allowlist.

### Reason

This prevents configuration drift between the security review and the actual proxy enforcement and matches the assignment requirement that policies be represented as files rather than prose.

---

## 28. Portable Environment Separation

### Decision

Keep environment-specific infrastructure bootstrap separate from the portable Cap workload.

### Chosen

- Helm: portable Cap workload and workload-level proxy configuration.
- Local environment bootstrap: local registry, local customer-style proxy, customer CA, constrained-cluster-specific setup.
- Cloud environment: Terraform for cloud primitives and environment bootstrap.

### Trade-off

The local implementation necessarily contains Rancher Desktop/Moby-specific bootstrap logic, but those details must not leak into the Helm workload or customer deployment architecture.

### Principle

The same workload chart should be usable against different customer registries, Kubernetes environments, and egress implementations without depending on the local container runtime.

---

## Assignment Documentation Addendum

### Deployment approach

The implementation uses Terraform for the target cloud infrastructure and Helm for the CAP application workload. `install.sh` provides a single operational entry point for the local and cloud targets while keeping infrastructure provisioning and workload deployment clearly separated.

The upstream CAP application is treated as the source of truth and is not modified for the Kubernetes deployment. Kubernetes-specific configuration is provided through Helm values, Kubernetes policies, supporting manifests, and deployment automation.

### Image supply chain

All runtime images are explicitly inventoried and promoted into the customer-controlled private registry before deployment. Workloads use digest-pinned image references so that deployment does not depend on mutable tags.

The runtime inventory covers the CAP web application, CAP media server, MySQL, MinIO, MinIO client setup image, and the customer egress proxy. Build-stage images from the upstream Dockerfiles are treated as build dependencies rather than runtime dependencies.

A Kubernetes admission policy enforces the approved private registry requirement, providing a second control in addition to the installer configuration.

### Egress and TLS

The CAP namespace uses default-deny ingress and egress NetworkPolicies with narrowly scoped allow rules for required application communication. External HTTPS traffic is routed through the customer egress proxy.

The proxy uses an explicit destination allowlist and records denied CONNECT attempts. Upstream TLS verification is enabled and uses the customer CA; `ssl_insecure=false` is retained so that upstream certificate verification is not bypassed.

The deployment therefore separates internal service-to-service traffic from explicitly approved external egress rather than giving application workloads unrestricted Internet access.

### Least privilege

The deployment service account is namespace-scoped and uses only the Kubernetes permissions required to operate the CAP namespace. It is not granted cluster-admin privileges or access to unrelated namespaces and cluster-scoped resources.

Application service accounts have Kubernetes API token automount disabled where the workload does not require API access. This reduces the impact of a compromised application container and keeps Kubernetes control-plane access outside the normal application path.

### Stateful services

MySQL and MinIO are deployed as stateful components with persistent storage rather than relying on ephemeral container filesystems. The application connects to these services through Kubernetes Services, keeping the workload dependency boundary explicit.

MinIO setup is performed through the dedicated setup image and Kubernetes hook workflow rather than requiring changes to the upstream application source.

### Rollback decision

Rollback is treated as the primary recovery mechanism during the change window rather than fix-forward. A deliberate invalid image deployment was used to create an `ImagePullBackOff` condition, after which the Helm release was rolled back to the known-good revision.

The rollback evidence is retained under `verification/lifecycle/rollback/` and demonstrates recovery from a partially failed release rather than only a successful first deployment.

### Evidence-driven verification

Operational and security claims are backed by artifacts under `verification/`. The evidence set includes private-registry image verification, admission-control results, NetworkPolicy state, customer-egress TLS and denial tests, rollback evidence, and uninstall evidence.

The intent is that the repository documents not only the intended architecture but also the observable evidence used to verify that the controls actually behaved as designed.
