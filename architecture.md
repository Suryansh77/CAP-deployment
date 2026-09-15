# Cap Self-Hosted Kubernetes Deployment

## 1. Purpose

This repository contains the infrastructure and deployment configuration for running Cap in a Kubernetes environment under enterprise-style security and connectivity constraints.

The deployment is based on Cap's existing self-hosted Docker Compose architecture. The Cap application source will be treated as upstream and will not be modified.

## 2. Supported Application Scope

The baseline deployment will cover the core self-hosted Cap stack:

- Cap Web
- Cap Media Server
- MySQL
- MinIO-compatible object storage

Optional integrations such as email providers, OAuth providers, AI providers, WorkOS, CloudFront, and other Cap Cloud integrations will not be enabled in the baseline deployment unless they are required for a specific demonstrated use case.

The goal is to minimize unnecessary external dependencies and keep the customer's network and security surface as small as practical.

## 3. High-Level Application Architecture


The Kubernetes deployment will preserve the core architecture of Cap's existing self-hosted Compose deployment.

~~~

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
                 +--------+    |   +-------------+
                 |             |                 |
                 v             v                 v
            +---------+   +---------+     +-------------+
            |  MySQL  |   |  MinIO  |     | Media       |
            |  :3306  |   |  :9000  |     | Server      |
            +----+----+   +----+----+     |   :3456     |
                 |             |           +------+-------+
                 v             v                  |
                PVC           PVC                 |
                                                   |
                                                   v
                                               Cap Web
                                    
~~~

## 4. Kubernetes Resource Model

| Cap component | Kubernetes resource | Reason |
|---|---|---|
| Cap Web | Deployment | Stateless web/application process |
| Media Server | Deployment | Stateless media-processing service |
| MySQL | StatefulSet + PersistentVolumeClaim | Persistent database state |
| MinIO | StatefulSet + PersistentVolumeClaim | Persistent object storage |
| Cap Web configuration | ConfigMap / Secret | Separate non-sensitive and sensitive configuration |
| Media Server credentials | Secret | Protect the shared authentication secret |
| Cap Web | ClusterIP Service | Stable internal access to the application |
| Media Server | ClusterIP Service | Stable internal access from Cap Web |
| MySQL | ClusterIP Service | Stable database endpoint |
| MinIO | ClusterIP Service | Stable internal S3 endpoint |
| External access | Ingress | Expose Cap Web through the cluster ingress |


## 5. Core Internal Network Flows

The Kubernetes deployment will use Kubernetes Services for stable service-to-service communication.

| Source | Destination | Port | Purpose |
|---|---|---:|---|
| Ingress | Cap Web | 3000 | User/application access |
| Cap Web | MySQL | 3306 | Application database access |
| Cap Web | MinIO | 9000 | S3-compatible object storage |
| Cap Web | Media Server | 3456 | Media processing requests |
| Media Server | Cap Web | 3000 | Progress and multipart callbacks |

The Media Server to Cap Web communication is authenticated using `MEDIA_SERVER_WEBHOOK_SECRET`.

The database and storage services will remain internal to the Kubernetes cluster and will not be exposed through the external ingress.


## 6. External Connectivity

The deployment will use a default-deny egress posture.

External connectivity will be permitted only where it is required by the selected supported functionality and will be documented by destination, port, originating component, and purpose.

The core self-hosted deployment does not require optional integrations such as Resend, Google OAuth, Apple OAuth, WorkOS, AI providers, or Cap Cloud services.

The Media Server can process media from externally supplied URLs. Any such outbound connectivity will therefore be treated as feature-dependent traffic rather than as an unrestricted application dependency.

Installation-time access to image registries and other infrastructure dependencies will be treated separately from runtime application egress.

## 7. Image Supply Chain

The deployment will use a customer-controlled private registry for Kubernetes runtime images.

The verified Cap runtime inventory includes:

- `ghcr.io/capsoftware/cap-web`
- `ghcr.io/capsoftware/cap-media-server`
- `mysql:8.0`
- `minio/minio`
- `minio/mc`

The Cap application images are published as multi-architecture images for Linux amd64 and arm64.

The Media Server image contains Bun and FFmpeg and is built from the Cap source. Its build process uses `oven/bun:1.4.0` as a base image.

The Cap Web image uses `oven/bun:1.4.0-alpine` during the build and `node:24-alpine` as its final runtime base.

Build-time images and alternate/local deployment images will be tracked separately from the images required by the final Kubernetes runtime.

The final deployment will use immutable image references or verified digests where practical rather than relying on mutable `latest` tags.

## 8. Configuration and Secrets

Sensitive configuration will be stored in Kubernetes Secrets rather than committed to the repository.

The deployment will generate unique values for:

- `NEXTAUTH_SECRET`
- `DATABASE_ENCRYPTION_KEY`
- `MEDIA_SERVER_WEBHOOK_SECRET`
- MySQL credentials
- MinIO credentials

Non-sensitive application configuration will be supplied separately from secrets.

The main internal service endpoints will use Kubernetes Service DNS names rather than hard-coded pod IP addresses.

The baseline deployment will configure:

- `DATABASE_URL` to the MySQL Service
- `S3_INTERNAL_ENDPOINT` to the MinIO Service
- `MEDIA_SERVER_URL` to the Media Server Service
- `MEDIA_SERVER_WEBHOOK_URL` to the Cap Web Service

Optional integration credentials will not be populated unless the corresponding feature is intentionally enabled.

## 9. Storage and Stateful Components

MySQL and MinIO will be treated as stateful workloads and will use PersistentVolumeClaims for their data.

The local Kubernetes environment currently provides the `local-path` StorageClass with dynamic provisioning. This will be used for the baseline local deployment.

The application pods will not store persistent application state in their container filesystems.

MySQL persistence will cover the database data directory.

MinIO persistence will cover the object-storage data directory.

Storage requirements for the real cloud deployment will be evaluated separately because the local `local-path` storage model is not assumed to be equivalent to production-grade shared or managed storage.

Backups and recovery of MySQL and MinIO data will be treated as operational requirements and documented in the runbook.

## 10. Security Model

The deployment will follow a least-privilege security model.

The application will run in a dedicated Kubernetes namespace with namespace-scoped service accounts and RBAC.

External access will be limited to the Cap Web entry point. MySQL, MinIO, and the Media Server will remain internal services.

NetworkPolicies will implement default-deny behavior and explicitly permit only required application communication.

Runtime container security settings will be applied where compatible with the upstream images, including non-root execution, read-only filesystems, and dropped Linux capabilities where practical.

Admission controls will be used to enforce selected deployment requirements such as approved image registries and secure workload configuration.

Secrets will not be committed to the repository. Verification will include both successful deployment tests and deliberate negative tests demonstrating that prohibited access is denied.

## 11. Deployment Targets

The deployment will be designed to run consistently across two environments.

### Customer-like Kubernetes Environment

The local Kubernetes cluster will be used to reproduce the customer's constrained deployment model during development and verification.

The current environment is Rancher Desktop running K3s with:

- Kubernetes v1.36.4
- `local-path` as the default StorageClass
- Traefik as the default IngressClass

This environment is used for functional and security testing and is not considered production-equivalent infrastructure.

### Public Cloud Environment

The same Helm application deployment will be used on one public-cloud Kubernetes environment.

Cloud infrastructure will be provisioned with Terraform where applicable.

The application packaging and configuration will remain separate from cloud-specific infrastructure so that the same Helm release can be reproduced across both targets.

## 12. Installation, Verification, and Reversibility

The deployment will be designed so that an operator can install the Cap workload using a documented and reproducible procedure.

Verification will cover:

- Kubernetes resources becoming healthy
- Cap Web availability
- Media Server health
- MySQL connectivity
- MinIO availability and bucket initialization
- required internal service communication
- security controls and policy enforcement

Negative tests will deliberately demonstrate that prohibited image sources, network access, and unauthorized Kubernetes actions are denied.

The deployment will support controlled upgrades and rollback using Helm.

The final verification will also demonstrate that the environment can be cleanly removed and that the operator has documented recovery steps for partially applied or failed deployments.

## Assignment Documentation Addendum

### Deployment model

The deployment is intentionally split into two layers. Terraform provisions the cloud infrastructure required for the target environment, while Helm manages the CAP workload inside the customer namespace. `install.sh` is the single entry point and exposes the two supported targets: `./install.sh local` for the local Rancher Desktop environment and `./install.sh cloud` for the GKE target.

The upstream CAP application source is not modified. Kubernetes-specific behavior is implemented outside the application through Helm values, Kubernetes policies, customer-egress infrastructure, and deployment automation.

### Runtime components and dependency boundary

The runtime deployment contains the CAP web application, CAP media server, MySQL, MinIO, the MinIO client used for setup, and the customer egress proxy. Runtime images are promoted into the customer/private registry and deployed using immutable digest references rather than floating tags. Build-stage images used by the upstream Dockerfiles are not runtime dependencies and are therefore not deployed to the cluster.

The application data path remains inside the customer environment: the web application communicates with MySQL, MinIO, and the media server through Kubernetes networking. External HTTPS access is forced through the customer egress proxy rather than allowing workloads unrestricted Internet access.

### Customer security constraints mapped to the architecture

The CAP namespace starts from default-deny ingress and egress NetworkPolicies and adds only the communication paths required by the workload. External access is mediated by the customer egress proxy, whose allowlist is explicit and whose upstream TLS verification uses the customer CA with `ssl_insecure=false`.

A private-registry admission policy rejects workload images that are not sourced from the approved private registry. Runtime service accounts do not automatically receive Kubernetes API credentials, and the deployment service account is namespace-scoped rather than cluster-admin.

The design also avoids introducing public telemetry, public S3, Sentry, Tinybird, Cap Cloud, Vercel, or other external control-plane dependencies into the baseline deployment. Any future external integration would require an explicit customer approval and corresponding allowlist entry.

### Environment-specific versus portable layers

The Helm workload and Kubernetes policy model are designed to remain largely runtime-neutral. Environment-specific behavior is concentrated in infrastructure provisioning, private-registry promotion, ingress configuration, storage defaults, and the customer egress implementation.

The current local validation was performed on Rancher Desktop and is useful for workload, Helm, RBAC, admission, proxy, and lifecycle validation. Some cluster-level guarantees are intended to be validated on the cloud target as well, because Kubernetes distributions and local runtimes can differ in their enforcement behavior.

### Evidence

Detailed evidence is retained under `verification/`, including image inventory and verification, admission-control verification, network-policy state, customer-egress TLS tests and denial logs, lifecycle rollback evidence, and uninstall evidence. These artifacts are intended to make the security and operational claims independently checkable rather than relying only on prose.
