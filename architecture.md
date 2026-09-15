# Cap Self-Hosted Kubernetes Deployment

## 1. Purpose

This repository contains the infrastructure and deployment configuration for running Cap in Kubernetes under enterprise-style security, connectivity, and software supply-chain constraints.

The deployment is derived from Cap's existing self-hosted Docker Compose architecture. The upstream Cap application source is not modified. Kubernetes-specific behavior is implemented outside the application through Helm values, Kubernetes policies, supporting manifests, infrastructure-as-code, and deployment automation.

The deployment is split into two layers:

- Terraform provisions the required cloud infrastructure primitives.
- Helm manages the Cap Kubernetes workload.

`install.sh` is the single operator entry point and provides the supported local and cloud deployment paths.

The architecture is designed around the following requirements:

- default-deny network communication;
- controlled customer egress;
- customer-style TLS interception;
- private-registry-only runtime images;
- immutable image references;
- admission enforcement;
- namespace-scoped RBAC;
- least-privilege workload identities;
- internal stateful storage;
- reproducible installation;
- rollback and uninstall support; and
- evidence-backed verification.

The baseline deployment intentionally minimizes external dependencies. Application traffic and state remain inside the customer environment unless a specific external dependency is explicitly required and represented in the egress policy.

---

## 2. Supported Application Scope

The baseline deployment covers the core self-hosted Cap stack:

- Cap Web
- Cap Media Server
- MySQL
- MinIO-compatible object storage

The runtime environment also contains:

- the MinIO client used for storage initialization;
- the customer egress proxy used to control approved external HTTPS connectivity;
- Kubernetes Services for internal service discovery; and
- Ingress configuration for the Cap Web entry point.

Optional integrations such as email providers, OAuth providers, AI providers, WorkOS, CloudFront, and other Cap Cloud integrations are not enabled in the baseline deployment.

The baseline does not require:

- public AWS S3;
- Tinybird;
- Sentry;
- OpenTelemetry;
- Cap Cloud;
- Vercel; or
- other external control-plane services.

This keeps the runtime dependency boundary small and makes the network policy easier to reason about.

The application data path is internal to Kubernetes:

- Cap Web uses MySQL for application data.
- Cap Web uses MinIO for S3-compatible object storage.
- Cap Web uses the Media Server for media-processing operations.
- The Media Server communicates back to Cap Web for progress and multipart callbacks.

The MinIO client is used only for storage initialization and is not part of the steady-state application request path.

---

## 3. High-Level Application Architecture

The Kubernetes deployment preserves the core architecture of the self-hosted Compose deployment.

```text
                           User / Cap Desktop
                                  |
                                  v
                           +-------------+
                           |   Ingress   |
                           +------+------+
                                  |
                                  v
                           +-------------+
                           |   Cap Web   |
                           |    :3000    |
                           +--+----+---+-+
                              |    |   |
                 +------------+    |   +----------------+
                 |                 |                    |
                 v                 v                    v
            +---------+       +---------+        +-------------+
            |  MySQL  |       |  MinIO  |        |   Media     |
            |  :3306  |       |  :9000  |        |   Server    |
            +----+----+       +----+----+        |   :3456     |
                 |                 |              +------+------+
                 v                 v                     |
                PVC               PVC                    |
                                                        |
                                                        v
                                                   Cap Web

                    External HTTPS, where explicitly required
                                  |
                                  v
                        +----------------------+
                        | Customer Egress Proxy|
                        |       :8080          |
                        +----------+-----------+
                                   |
                                   v
                          Approved external FQDNs
```

Cap Web is the only application workload exposed through the cluster ingress.

MySQL, MinIO, and the Media Server remain internal Kubernetes Services.

The customer egress proxy is deployed separately from the Cap application namespace. This creates an explicit trust boundary between the application environment and approved external connectivity.

The application is therefore divided into three traffic classes:

1. External client traffic enters through the cluster ingress and reaches Cap Web.
2. Internal application traffic uses Kubernetes Services.
3. Explicitly approved external HTTPS traffic is sent through the customer egress proxy.

---

## 4. Kubernetes Resource Model

| Component | Kubernetes resource | Purpose |
|---|---|---|
| Cap Web | Deployment | Stateless web/application process |
| Media Server | Deployment | Stateless media-processing service |
| MySQL | StatefulSet + PersistentVolumeClaim | Persistent database state |
| MinIO | StatefulSet + PersistentVolumeClaim | Persistent object storage |
| MinIO setup | Kubernetes Job / Helm hook | Storage initialization |
| Cap Web configuration | ConfigMap / Secret | Non-sensitive and sensitive configuration |
| Media Server credentials | Secret | Protect shared authentication material |
| Cap Web | ClusterIP Service | Stable internal application endpoint |
| Media Server | ClusterIP Service | Stable internal media endpoint |
| MySQL | ClusterIP Service | Stable database endpoint |
| MinIO | ClusterIP Service | Stable object-storage endpoint |
| External application access | Ingress | Cluster entry point for Cap Web |
| Customer egress proxy | Deployment + Service | Controlled external HTTPS path |
| Customer egress configuration | ConfigMap / Secret | Allowlist and TLS material |
| Admission control | ValidatingAdmissionPolicy + Binding | Private-registry enforcement |
| Network isolation | NetworkPolicy | Default-deny and narrow communication paths |

The Cap workload is deployed into the `cap` namespace.

The customer egress proxy is deployed separately in the `customer-egress` namespace.

The operational deployment identity is namespace-scoped and does not require cluster-admin permissions.

Application ServiceAccounts do not receive Kubernetes API credentials where the application does not require Kubernetes API access.

---

## 5. Core Internal Network Flows

All normal service-to-service communication uses Kubernetes Services.

| Source | Destination | Port | Purpose |
|---|---|---:|---|
| Ingress | Cap Web | 3000 | User/application access |
| Cap Web | MySQL | 3306 | Application database |
| Cap Web | MinIO | 9000 | S3-compatible object storage |
| Cap Web | Media Server | 3456 | Media-processing requests |
| Media Server | Cap Web | 3000 | Progress and multipart callbacks |
| MinIO setup | MinIO | 9000 | Bucket/storage initialization |

The Media Server to Cap Web path is authenticated using `MEDIA_SERVER_WEBHOOK_SECRET`.

The Cap namespace starts with namespace-wide default-deny ingress and egress NetworkPolicies. Required communication is then enabled through narrow directional policies.

The policy model explicitly separates ingress and egress direction. This is important because Kubernetes NetworkPolicy direction is independent and separate policy objects must have unique names.

The network policy set explicitly permits only the required paths, including:

- DNS;
- Ingress to Cap Web;
- Cap Web to MySQL;
- Cap Web to MinIO;
- Cap Web to Media Server;
- Media Server to Cap Web;
- MinIO setup to MinIO; and
- application workloads to the customer egress proxy where required.

MySQL and MinIO are never exposed through the public ingress path.

The intended internal communication model is therefore:

```text
Ingress
   |
   v
Cap Web
 |  |  \
 |  |   \
 v  v    v
DB MinIO Media Server
          |
          v
       Cap Web
```

---

## 6. External Connectivity

The runtime deployment uses default-deny egress.

Application workloads are not given unrestricted Internet access. External HTTPS connectivity is mediated by the customer egress proxy.

The proxy uses an explicit allowlist. Each allowlist entry is defined by:

- destination FQDN;
- destination port;
- originating component;
- reason the destination is required; and
- whether the dependency is install-time or permanent runtime traffic.

The policy source is:

```text
policies/egress-allowlist.yaml
```

The proxy configuration is generated from the approved policy rather than being treated as an implicit collection of broad network exceptions.

The customer-style TLS model is:

1. The application connects to the egress proxy.
2. The proxy terminates the workload-side TLS connection.
3. The proxy uses the customer CA to establish the trusted interception boundary.
4. The proxy connects upstream to the destination.
5. Upstream certificate verification remains enabled.
6. `ssl_insecure=false` is retained.

The tested customer-style CA is:

```text
Zamp Customer Egress CA
```

A negative test against an unallowlisted destination was used to verify enforcement:

```text
example.com:443
```

The expected result is an explicit proxy denial rather than a timeout. The verified behavior returned HTTP 403 and produced the proxy log entry:

```text
EGRESS DENY CONNECT host=example.com port=443
```

The corresponding evidence is retained under:

```text
verification/egress/
verification/logs/
```

The architecture also supports the stronger post-install air-gap check required by the assignment: after installation, the proxy can be placed into full-deny mode while the already-installed Cap application continues serving through its internal dependencies. This demonstrates that application availability does not depend on unrestricted external connectivity.

The baseline application does not require public S3, Tinybird, Sentry, OpenTelemetry, Cap Cloud, Vercel, or similar external services.

Installation-time image-registry and infrastructure access is intentionally treated as a different concern from runtime application egress.

---

## 7. Image Supply Chain

The Kubernetes runtime uses a customer-controlled private registry.

The runtime image inventory includes:

- `ghcr.io/capsoftware/cap-web`
- `ghcr.io/capsoftware/cap-media-server`
- `mysql:8.0`
- `minio/minio`
- `minio/mc`
- customer egress proxy image

The final cloud deployment promotes these runtime images into the customer Artifact Registry before the workload is installed.

The cloud workload references the promoted images using immutable digest references.

The supply-chain control therefore has two layers:

1. The deployment automation selects the approved private-registry image digests.
2. Kubernetes admission independently rejects images that are outside the approved private registry.

The upstream build-stage dependencies are tracked separately from runtime images.

Identified build-stage images include:

- `oven/bun:1.4.0-alpine`
- `oven/bun:1.4.0`
- `node:24-alpine`

These are build dependencies and are not deployed as runtime Kubernetes workloads.

The Media Server image contains Bun and FFmpeg and is built from the Cap source.

The Cap Web image uses Bun during its build and Node as its final runtime base.

The image inventory and independent verification are documented in:

```text
verification/image-inventory.md
verification/image-verification.md
```

The local Apple Silicon image promotion is a single-platform registry copy. The repository does not claim that the local registry artifacts are multi-architecture.

The private registry itself is treated as a separate supply-chain boundary from the Kubernetes workload.

---

## 8. Configuration and Secrets

Sensitive configuration is stored in Kubernetes Secrets and is not committed to the repository.

The deployment generates or supplies unique values for:

- `NEXTAUTH_SECRET`
- `DATABASE_ENCRYPTION_KEY`
- `MEDIA_SERVER_WEBHOOK_SECRET`
- MySQL credentials
- MinIO credentials

The primary internal service configuration uses Kubernetes Service DNS rather than Pod IP addresses.

The workload uses internal service endpoints for:

```text
DATABASE_URL
S3_INTERNAL_ENDPOINT
MEDIA_SERVER_URL
MEDIA_SERVER_WEBHOOK_URL
```

The service endpoints resolve through Kubernetes Services and therefore remain stable across Pod replacement.

Optional external integration credentials are not populated in the baseline deployment.

Customer egress TLS material and proxy configuration are isolated from application source code and are injected during environment setup.

---

## 9. Storage and Stateful Components

MySQL and MinIO are deployed as stateful workloads.

Both use PersistentVolumeClaims so that database and object-storage state survives individual container replacement.

The local environment provides the `local-path` StorageClass and uses it for the local target.

The cloud environment provisions storage through the target Kubernetes platform rather than assuming that the local storage implementation is identical to the cloud storage implementation.

MySQL persistence covers the database data directory.

MinIO persistence covers the object-storage data directory.

MySQL and MinIO remain internal services and are not exposed through the application ingress.

The MinIO setup workflow uses the dedicated MinIO client and initializes the required storage configuration through the Helm lifecycle rather than modifying the upstream application.

The storage model therefore separates:

- application lifecycle;
- database persistence;
- object-storage persistence; and
- initialization logic.

---

## 10. Security Model

The deployment uses layered controls rather than relying on a single Kubernetes mechanism.

### Network isolation

The Cap namespace starts with default-deny ingress and egress NetworkPolicies.

Only required traffic paths are allowed.

External egress to the customer proxy is explicitly permitted while direct unrestricted external access is not.

### Kubernetes RBAC

The deployment identity is namespace-scoped.

The deployment role permits only the Kubernetes operations required for deployment and diagnosis, including the necessary workload, Secret, NetworkPolicy, and Pod/log operations.

It does not grant:

- node access;
- namespace creation;
- ClusterRole creation;
- ClusterRoleBinding creation;
- unrelated persistent-volume access; or
- access to unrelated application namespaces.

The application ServiceAccount is deliberately more restricted and does not require an application RoleBinding for normal operation.

Service-account token automount is disabled where Kubernetes API access is unnecessary.

### Container security

Runtime security settings are applied where compatible with the upstream images.

The customer egress proxy is hardened with:

- non-root execution;
- dropped Linux capabilities;
- read-only root filesystem;
- RuntimeDefault seccomp profile;
- resource controls; and
- disabled service-account token automount.

Cap Web and Media Server are configured to run with explicit non-root numeric identities where required by the platform security policy.

### Admission control

A Kubernetes `ValidatingAdmissionPolicy` and binding enforce the private-registry requirement.

A workload using an image from an unapproved public registry is rejected.

A compliant private digest-pinned image is accepted.

The policy also covers init containers so that a workload cannot bypass the image-source control by introducing an unapproved auxiliary image.

### Secrets

Secrets are generated or supplied at installation time and are not committed to the repository.

### Security verification

The deployment includes positive and negative verification for:

- private-registry image acceptance;
- public-registry image rejection;
- init-container image rejection;
- namespace-scoped RBAC;
- cluster-scoped RBAC denial;
- cross-namespace denial;
- NetworkPolicy enforcement;
- customer egress allow/deny behavior; and
- customer-style TLS interception.

---

## 11. Deployment Targets

The deployment deliberately separates the Kubernetes workload from the environment-specific bootstrap.

### Customer-like Kubernetes Environment

The local target is Rancher Desktop running K3s with:

- Kubernetes v1.36.4;
- `local-path` as the default StorageClass;
- Traefik as the default IngressClass; and
- the Moby/Docker container runtime.

The local target is used to exercise:

- Helm deployment;
- application startup;
- MySQL and MinIO state;
- MinIO initialization;
- NetworkPolicies;
- admission control;
- RBAC;
- customer egress behavior;
- image pull behavior;
- rollback; and
- uninstall.

The local private-registry path was also exercised as part of the constrained environment. The registry uses HTTPS and a trusted customer-style certificate rather than relying on an insecure HTTP registry exception.

This is important because the local environment's Moby-based image-pull path does not behave identically to a K3s configuration that controls the container runtime directly. The final Helm workload therefore remains runtime-neutral and does not depend on Moby-specific behavior.

### Public Cloud Environment

The cloud target is GKE provisioned with Terraform.

The cloud installer performs the environment-specific bootstrap required for the customer-like environment, including:

1. provisioning the GKE and supporting cloud infrastructure;
2. obtaining GKE credentials;
3. authenticating to Artifact Registry;
4. promoting the required runtime images;
5. resolving their private digest references;
6. generating customer-style egress TLS material;
7. creating the application and customer-egress namespaces;
8. creating the required Secrets and ConfigMaps;
9. applying NetworkPolicies;
10. configuring ingress;
11. applying the private-registry admission policy;
12. rendering the Helm workload with private digest-pinned images; and
13. installing the Cap release.

The resulting cloud workload uses the same core Helm deployment model as the local target.

The cloud environment was exercised through the full application installation path, including:

- private registry promotion;
- admission enforcement;
- customer egress proxy;
- final NetworkPolicy state;
- final Pod state;
- ingress verification; and
- application availability.

The cloud-specific infrastructure is kept outside the core workload packaging so that the Helm deployment does not become coupled to Terraform resource definitions.

---

## 12. Installation, Verification, and Reversibility

The primary operator interface is:

```text
./install.sh local
./install.sh cloud
```

The local path installs the workload into the constrained Kubernetes environment.

The cloud path provisions the required Terraform infrastructure and then performs the Kubernetes deployment.

The installation flow is intentionally ordered so that dependency failures are discovered before or during the relevant stage rather than being hidden behind a long-running application timeout.

### Installation verification

Verification covers:

- Helm release state;
- Pod readiness;
- Service availability;
- Ingress behavior;
- MySQL connectivity;
- MinIO availability and initialization;
- Media Server health;
- NetworkPolicy state;
- admission state;
- runtime image provenance;
- customer egress behavior; and
- application HTTP availability.

The cloud deployment reached a deployed Helm state and the application returned the expected HTTP response.

The final cloud workload was verified to use private Artifact Registry image references with immutable digests.

### Security verification

The repository contains evidence for the core enforcement controls:

```text
verification/image-inventory.md
verification/image-verification.md
verification/egress/
verification/logs/
```

Relevant cloud evidence includes:

```text
verification/logs/cloud-application-serving.txt
verification/logs/cloud-final-admission-policy.yaml
verification/logs/cloud-final-cap-networkpolicies.txt
verification/logs/cloud-final-cap-pods.txt
verification/logs/cloud-final-egress-networkpolicies.txt
verification/logs/cloud-final-egress-pods.txt
verification/logs/cloud-ingress.txt
```

Customer egress denial evidence includes:

```text
verification/egress/cloud-proxy-denial.txt
verification/egress/cloud-proxy-denial-log.txt
verification/logs/proxy-denial.txt
verification/logs/proxy-denial-log.txt
```

### Rollback

Helm is the release and rollback mechanism.

Rollback is the preferred recovery path during the customer change window rather than fix-forward.

The rollback test deliberately introduced an invalid image digest and produced an `ImagePullBackOff` condition. The release was then returned to a known-good Helm revision.

The rollback procedure also accounts for a failed revision leaving a stale failed Pod behind; the stale resource must be inspected and removed when necessary so that the controller can recreate the healthy replacement.

Rollback evidence is retained under:

```text
verification/lifecycle/rollback/
```

### Uninstall

The workload uninstall entry point is:

```text
./uninstall.sh
```

The uninstall operation removes the Helm release and associated application resources, including the customer-egress namespace and application namespace.

It verifies removal of:

- the `cap` namespace;
- the `customer-egress` namespace;
- the Helm release;
- the private-registry admission policy; and
- targeted Cap persistent storage.

The customer private registry is treated as a separate bootstrap dependency and is intentionally not removed by the application uninstall.

Uninstall evidence is retained under:

```text
verification/lifecycle/uninstall/
```

### Cloud reversibility

Workload uninstall and complete cloud-environment teardown are separate operations.

The temporary GKE environment can be removed independently of the application workload teardown. Terraform is used for the infrastructure layer, while the Kubernetes workload remains managed by Helm.

The completed cloud teardown was verified to remove the temporary target infrastructure while preserving the unrelated existing cloud environment.

### Evidence-first operating model

The architecture is intentionally coupled to repository evidence.

The repository records:

- the final image inventory;
- private-registry promotion;
- admission enforcement;
- RBAC authorization and denial;
- NetworkPolicy state;
- customer egress allow/deny behavior;
- TLS interception;
- application availability;
- rollback behavior; and
- uninstall behavior.