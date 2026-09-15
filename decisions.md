# Engineering Decisions

This document records the material engineering decisions made while converting the upstream Cap self-hosted deployment into a constrained Kubernetes deployment.

For each decision, the document records the choice, the alternative rejected, the reasoning or trade-off, and the verification evidence where applicable.

---

## 1. Overall Approach

### Decision

Build the deployment around a namespace-scoped Helm workload with the customer security and connectivity controls implemented outside the Cap application.

### Chosen

- Helm for Kubernetes workload deployment.
- Terraform for public-cloud infrastructure.
- Kubernetes NetworkPolicy for default-deny and explicitly permitted communication.
- Namespace-scoped RBAC with no cluster-admin dependency.
- Private-registry-only runtime images.
- Immutable digest-pinned runtime image references.
- Kubernetes-native admission enforcement.
- Customer egress proxy for explicitly approved external connectivity.
- Evidence retained under `verification/`.

### Rejected

Modifying the upstream Cap application to satisfy infrastructure, security, or Kubernetes requirements.

### Reason

The assignment requires the application to remain unmodified. The infrastructure layer must adapt around the existing application rather than changing Cap itself.

### Trade-off

This places more responsibility on Helm, Kubernetes policy, and deployment automation, but keeps the application source clean and makes the deployment controls independently reviewable.

---

## 2. Local Kubernetes Environment

### Decision

Use Rancher Desktop as the constrained local customer-like Kubernetes environment.

### Chosen

- Rancher Desktop v1.24.0.
- Kubernetes v1.36.4.
- `local-path` StorageClass.
- Traefik IngressClass.
- Moby/Docker container runtime.

### Rejected

Building a custom local Kubernetes distribution solely to reproduce the assignment.

### Reason

The assignment is specifically testing whether the deployment can operate inside an imperfect existing environment. Rancher Desktop provides a realistic constrained development target and exposes runtime-specific behavior that can be diagnosed rather than hidden.

### Trade-off

The local environment is not identical to the GKE environment, particularly around storage and runtime behavior. The workload packaging therefore remains runtime-neutral while environment-specific bootstrap is isolated.

---

## 3. Container Runtime Choice

### Decision

Keep the existing Moby/Docker runtime for the local target.

### Chosen

Moby/Docker remains a local bootstrap concern only. No Moby-specific assumptions are embedded into the Helm workload.

### Rejected

Replacing the local runtime mid-implementation.

### Reason

The Kubernetes environment and image store were already functioning, and replacing the runtime would have introduced unnecessary environment churn.

### Trade-off

The local registry configuration had to account for Moby's image-pull behavior, while the Helm workload itself remained independent of that implementation detail.

---

## 4. Helm Namespace Handling

### Decision

Do not make namespace creation part of the application Helm chart.

### Chosen

The workload is installed into the `cap` namespace using the deployment workflow rather than making namespace lifecycle a core chart responsibility.

### Rejected

Granting the application release broad cluster-level permission to manage namespaces.

### Reason

The customer environment provides a shared cluster and namespace-scoped access. The workload should not imply that cluster-admin privileges are required.

### Trade-off

Namespace lifecycle remains an environment/bootstrap concern, but the application chart stays better aligned with the shared-cluster security model.

---

## 5. Runtime Security Context

### Decision

Run application and supporting workloads with explicit non-root security settings where required.

### Problem Encountered

The initial Cap Web image used a named user that could not satisfy the cluster's static non-root validation, while the Media Server image ran as root.

### Resolution

Explicit numeric identities and non-root enforcement were added for the affected workloads.

The hardened configuration uses:

- `runAsUser`
- `runAsGroup`
- `runAsNonRoot: true`
- `allowPrivilegeEscalation: false`
- dropped Linux capabilities
- RuntimeDefault seccomp where applicable
- disabled ServiceAccount token automount where Kubernetes API access is unnecessary

### Rejected

Disabling the cluster security requirement or running the application containers as root.

### Reason

The security control is part of the customer environment and should be satisfied rather than bypassed.

### Evidence

The original failure and remediation were exercised during implementation.

---

## 6. NetworkPolicy Model

### Decision

Use namespace-wide default-deny ingress and egress with explicit narrow allow rules.

### Chosen

The Cap namespace begins with default-deny ingress and egress.

Required paths are then permitted explicitly for:

- DNS;
- Ingress to Cap Web;
- Cap Web to MySQL;
- Cap Web to MinIO;
- Cap Web to Media Server;
- Media Server to Cap Web;
- MinIO setup to MinIO; and
- required workload access to the customer egress proxy.

### Rejected

Broad namespace-wide allow rules.

### Reason

The customer requirement is least-privilege communication with default deny.

### Trade-off

More policy objects and explicit directional rules are required, but the resulting network boundary is easier to audit and troubleshoot.

---

## 7. NetworkPolicy Direction and Naming

### Decision

Use unique NetworkPolicy objects for separate ingress and egress directions.

### Failure Encountered

An ingress and egress policy initially used the same Kubernetes object name. Applying the second object replaced the first because NetworkPolicy identity is namespace plus name.

### Symptom

Media Server to Cap Web communication failed even though the expected policy appeared to have been applied.

### Resolution

Separate unique policies were used, including:

- `allow-media-server-to-web`
- `allow-media-server-to-web-ingress`

### Lesson

NetworkPolicy direction is independent, and separate policy objects must have unique names.

### Evidence

`verification/logs/networkpolicy-media-to-web-incident.txt`

---

## 8. Internal Object Storage Instead of Public S3

### Decision

Use internal MinIO for the baseline self-hosted deployment.

### Chosen

Block public AWS S3 access in the baseline and use the internal MinIO Service for object storage.

### Rejected

Allowing `s3.amazonaws.com:443` by default.

### Reason

The baseline self-hosted deployment does not require public S3. Keeping object storage inside the Kubernetes environment reduces external data movement and simplifies the egress policy.

### Verification

A public S3 request was blocked while the internal MinIO path returned successfully.

### Evidence

`verification/logs/s3-egress-investigation.txt`

---

## 9. Tinybird Analytics

### Decision

Do not enable external Tinybird egress in the baseline.

### Chosen

No Tinybird hostname or token is configured, and no Tinybird destination is present in the baseline allowlist.

### Rejected

Adding a broad Tinybird Internet exception simply because the source contains integration code.

### Reason

Source-level integration capability does not establish a runtime dependency for the selected self-hosted deployment.

### Trade-off

Optional analytics functionality is excluded in exchange for a smaller and more controlled network boundary.

### Evidence

`verification/logs/tinybird-egress-investigation.txt`

---

## 10. Cap.so and Vercel Integrations

### Decision

Do not allow baseline egress to Cap Cloud/Vercel control-plane endpoints.

### Chosen

The baseline does not permit `cap.so`, `api.vercel.com`, or other Vercel-specific external control-plane destinations.

### Rejected

Allowing those domains merely because optional Vercel integration code exists upstream.

### Reason

The self-hosted baseline can operate without those external services, and the customer explicitly requires that nothing leave the environment unless justified.

### Evidence

`verification/logs/cap-so-vercel-investigation.txt`

---

## 11. Sentry and OpenTelemetry

### Decision

Do not enable external telemetry in the baseline.

### Chosen

No Sentry DSN or external OTLP exporter endpoint is configured, and no external telemetry destination is included in the baseline allowlist.

### Rejected

Keeping external telemetry enabled by default.

### Reason

The customer requirement explicitly prohibits uncontrolled data leaving the environment, including telemetry and license-related traffic.

### Trade-off

External telemetry functionality is excluded from the baseline in favor of deterministic data-boundary control.

### Evidence

`verification/logs/sentry-otel-egress-investigation.txt`

---

## 12. Image Provenance Model

### Decision

Treat runtime images and build-stage images as separate supply-chain categories and deploy runtime images by immutable digest.

### Runtime Images Identified

The runtime inventory covers:

- Cap Web;
- Cap Media Server;
- MySQL;
- MinIO;
- MinIO Client setup image; and
- customer egress proxy.

### Build Images Identified

The upstream build process uses:

- `oven/bun:1.4.0-alpine`;
- `oven/bun:1.4.0`; and
- `node:24-alpine`.

### Rejected

Tracking only the obvious application images and ignoring supporting or build-stage image dependencies.

### Reason

The assignment explicitly asks the candidate to find every image and make image provenance independently verifiable.

### Chosen

Runtime images are promoted into the customer/private registry and referenced using immutable digest-pinned references.

### Evidence

`verification/image-inventory.md`

`verification/image-verification.md`

---

## 13. Private Registry

### Decision

Create a private registry for the local constrained target and use Artifact Registry for the cloud target.

### Local Choice

The local registry is exposed at:

`host.docker.internal:5001`

The Kubernetes workload reaches it through the container runtime network path.

### Cloud Choice

The GKE target uses a customer Artifact Registry repository for the promoted runtime images.

### Rejected

Allowing the Kubernetes workload to pull runtime images directly from public GHCR, Docker Hub, or Quay.

### Reason

The customer requires that runtime images originate from the customer-controlled registry boundary.

### Trade-off

The installer must perform image promotion before workload installation, but the resulting runtime supply chain is explicit and customer-controlled.

---

## 14. Private Registry HTTPS Remediation

### Decision

Use HTTPS for the local private registry rather than an insecure HTTP registry exception.

### Problem

The initial Kubernetes image pull failed because Moby attempted HTTPS while the local registry was serving HTTP.

### Observed Error

`http: server gave HTTP response to HTTPS client`

### Resolution

The local registry was recreated with HTTPS and a customer-style certificate. The corresponding trusted CA was provisioned into the local runtime trust path.

### Rejected

Keeping the registry on plain HTTP and weakening the container runtime with a broad insecure-registry exception.

### Reason

HTTPS better represents the regulated customer environment and creates a real certificate trust boundary.

### Evidence

- `verification/logs/private-registry-pull-failure.txt`
- `verification/logs/private-registry-pull-success.txt`

---

## 15. Registry Promotion

### Decision

Promote the exact observed runtime artifacts into the private registry rather than rebuilding unrelated substitutes.

### Runtime Artifacts Promoted

- Cap Web
- Cap Media Server
- MySQL
- MinIO
- MinIO Client

The customer egress proxy image is also promoted for the controlled runtime path.

### Verification

Each promoted registry repository returned a valid OCI or Docker v2 manifest.

### Rejected

Using mutable public image tags directly from the cluster.

### Reason

Promotion creates an explicit customer-owned supply-chain boundary and makes the runtime image source independently observable.

### Evidence

`verification/logs/private-registry-promotion.txt`

`verification/logs/private-registry-final-verification.txt`

---

## 16. Helm Image References

### Decision

Allow Helm to accept registry plus immutable digest references while retaining tag support for compatible environments.

### Chosen

The chart supports image references in the form:

`repository@sha256:digest`

### Rejected

Hard-coding GHCR, Docker Hub, or Quay addresses into the Kubernetes workload.

### Reason

The same Helm workload should be usable with different customer registries without introducing a registry-vendor dependency into the chart.

### Verification

Rendered manifests showed the runtime images using the private registry and immutable digests.

---

## 17. MinIO Initialization

### Decision

Represent MinIO bucket initialization as a Helm lifecycle hook Job.

### Chosen

The setup Job runs after installation and upgrade so that MinIO exists before initialization is attempted.

The final command sequence is:

1. configure the `mc` alias;
2. check MinIO readiness;
3. create the bucket idempotently.

### Security

The setup Job uses:

- a private-registry image;
- an immutable digest;
- non-root execution;
- `allowPrivilegeEscalation: false`;
- dropped Linux capabilities;
- RuntimeDefault seccomp;
- disabled ServiceAccount token automount; and
- only the MinIO network path required for setup.

### Failures Encountered

The hardened Job initially attempted to create its configuration under `/.mc` because of the non-root filesystem context.

After that was corrected with a writable temporary HOME, the next failure exposed incorrect use of `mc ready` against a raw endpoint.

### Resolution

The final flow configures an alias and then uses the alias for readiness and bucket creation.

### Evidence

- `verification/logs/minio-setup-hook-failure.txt`
- Helm history showing the failed and recovered revisions
- successful hook execution

---

## 18. Namespace-Scoped RBAC

### Decision

Use a dedicated `cap-deployer` ServiceAccount bound to a namespaced Role and RoleBinding.

### Chosen

The deployment identity receives only the namespace permissions needed to manage and diagnose the Cap release.

The application ServiceAccount remains separate and has:

`automountServiceAccountToken: false`

### Permission Model

The deployment identity can perform the required namespace-scoped operations, including workload, Secret, NetworkPolicy, Pod, and Pod/log operations required by the deployment workflow.

### Rejected

Granting:

- cluster-admin;
- built-in broad `edit`;
- built-in broad `admin`;
- node access;
- namespace creation;
- ClusterRole management;
- ClusterRoleBinding management;
- unrelated persistent-volume access; or
- unrelated namespace access.

### Reason

The customer provides a namespace on a shared cluster and explicitly does not grant cluster-admin access.

### Verification

Verified results included:

- required namespace operations permitted;
- cluster-scoped operations denied;
- cross-namespace access denied;
- application ServiceAccount token automount disabled;
- application ServiceAccount unable to access tested Kubernetes API resources.

### Evidence

`verification/logs/rbac-verification.txt`

---

## 19. Application Identity Separation

### Decision

Keep application identity separate from deployment identity.

### Chosen

The application ServiceAccount has no deployment RoleBinding and does not receive Kubernetes API credentials when they are unnecessary.

### Rejected

Using the deployment ServiceAccount for application Pods.

### Reason

A compromised application should not automatically inherit deployment privileges.

### Trade-off

The deployment automation has a separate operational identity, but the application runtime has a much smaller Kubernetes API attack surface.

---

## 20. Admission Control

### Decision

Use Kubernetes-native `ValidatingAdmissionPolicy` and `ValidatingAdmissionPolicyBinding` for the private-registry invariant.

### Chosen

The policy:

- is scoped to the Cap namespace;
- uses `failurePolicy: Fail`;
- uses `validationActions: [Deny]`;
- validates regular containers;
- validates init containers; and
- validates ephemeral containers.

### Security Invariant

A Pod admitted into the Cap namespace must use an image from the approved private registry.

### Rejected

Relying only on the installer to select the correct image source.

### Reason

Installer configuration does not protect against later manual workload deployment. Admission provides an independent enforcement layer.

### Implementation Issue

The first CEL implementation attempted to concatenate the typed container lists and produced a Kubernetes type-checking warning.

### Resolution

The expression was redesigned to validate the three container collections independently.

### Verification

The following tests were performed:

- public main-container image rejected;
- approved private image accepted;
- public init-container image rejected;
- rejected Pods were confirmed absent after the admission failure;
- final policy reported no expression warnings;
- binding used `Deny`.

### Evidence

`verification/logs/admission-control-verification.txt`

---

## 21. Customer Egress Proxy Architecture

### Decision

Use a separate customer egress proxy rather than permitting direct external connectivity from application Pods.

### Chosen

The proxy is deployed in the `customer-egress` namespace and provides:

- explicit destination allowlisting;
- CONNECT denial logging;
- TLS interception using the customer-style CA;
- upstream certificate verification; and
- a controlled network path from the Cap namespace.

### Rejected

Direct unrestricted Internet access from Cap Web or Media Server.

### Reason

The customer requirement is default-deny external connectivity with explicit endpoint justification.

### Security Model

The proxy runs with hardened container settings including:

- non-root user;
- dropped capabilities;
- read-only root filesystem;
- RuntimeDefault seccomp;
- resources; and
- disabled ServiceAccount token automount.

---

## 22. Customer TLS Interception

### Decision

Model the customer proxy as a TLS-intercepting trust boundary.

### Chosen

The proxy uses the customer-style CA and retains upstream certificate verification with:

`ssl_insecure=false`

### Rejected

Disabling upstream certificate verification to make intercepted HTTPS succeed.

### Reason

Doing so would weaken the security boundary and hide certificate-validation problems.

### Verification

The authorized TLS path was successfully validated using the customer-style:

`Zamp Customer Egress CA`

The test verified successful HTTPS behavior through the proxy while retaining upstream certificate validation.

### Evidence

Customer egress TLS evidence is retained under `verification/egress/` and `verification/logs/`.

---

## 23. Explicit Egress Allowlist

### Decision

Represent external connectivity as an explicit policy file rather than scattered proxy exceptions.

### Chosen

The policy source is:

`policies/egress-allowlist.yaml`

Each entry identifies:

- FQDN;
- port;
- component;
- reason; and
- install-time or permanent runtime classification.

### Rejected

A broad Internet allow rule or a wildcard destination policy.

### Reason

The assignment explicitly requires evidence-based endpoint allowlisting and a default-deny external posture.

### Trade-off

The application must identify every real external dependency, but the result is significantly easier for a customer security reviewer to approve.

---

## 24. Egress Denial Verification

### Decision

Use a known-unallowlisted destination as a negative verification signal.

### Chosen Test

`example.com:443`

### Expected Behavior

The proxy must reject the CONNECT request explicitly.

### Verified Result

The proxy returned:

`HTTP/1.1 403 Forbidden`

and recorded:

`EGRESS DENY CONNECT host=example.com port=443`

### Rejected

Using only a successful allowlist test.

### Reason

A successful test proves that allowed traffic works. The denial test proves that the boundary actually enforces the policy.

### Evidence

- `verification/egress/cloud-proxy-denial.txt`
- `verification/egress/cloud-proxy-denial-log.txt`
- `verification/logs/proxy-denial.txt`
- `verification/logs/proxy-denial-log.txt`

---

## 25. Verification-Only External Destination

### Decision

Use the negative external destination only for enforcement testing.

### Chosen

`example.com:443` is treated as a deliberately unallowlisted verification target.

### Rejected

Adding the destination to the permanent runtime allowlist simply to simplify testing.

### Reason

A verification destination must demonstrate the deny boundary rather than weakening it.

### Trade-off

The negative test depends on a deliberately blocked endpoint, but this makes the enforcement evidence concrete and repeatable.

---

## 26. Full-Deny Post-Install Model

### Decision

Treat the customer proxy as an independent runtime dependency boundary.

### Chosen

After installation, the proxy can be switched to full deny while the already-installed Cap application continues using its internal MySQL, MinIO, and Media Server paths.

### Rejected

Using application availability itself as proof that unrestricted Internet access is required.

### Reason

The strongest air-gap signal is that the application remains available after external egress is denied.

### Verification

The application continued serving after external proxy access was denied, while the internal application dependency paths remained available.

---

## 27. Policy as Source of Truth

### Decision

Keep security policy definitions in version-controlled policy files and derive enforced configuration from them.

### Chosen

The repository contains explicit NetworkPolicy and egress allowlist sources rather than relying on undocumented runtime configuration.

### Rejected

Manual production-only policy configuration that exists outside the repository.

### Reason

A customer platform team should be able to review the intended communication model before deployment and compare it with the enforced state afterward.

---

## 28. Portable Workload Versus Environment Bootstrap

### Decision

Separate the portable Kubernetes workload from environment-specific bootstrap.

### Chosen

The Helm workload remains independent of:

- Terraform resource definitions;
- Moby-specific registry behavior;
- local storage implementation;
- local ingress implementation; and
- cloud infrastructure details.

Environment-specific work is handled by the local or cloud installation path.

### Rejected

Embedding local runtime assumptions directly into the Helm workload.

### Reason

The assignment explicitly uses two deployment targets to test whether the Kubernetes abstraction is real rather than hand-fitted.

### Trade-off

The installer has more environment-specific logic, but the workload itself remains easier to reproduce across Kubernetes platforms.

---

## 29. Cloud Infrastructure as Code

### Decision

Use Terraform for the real cloud infrastructure layer.

### Chosen

Terraform provisions the disposable GKE environment and supporting cloud resources required by the deployment.

### Rejected

Manually creating the cloud cluster and infrastructure outside the repository.

### Reason

The assignment requires the environment itself to be code and the deployment to be reproducible from a controlled starting point.

### Trade-off

Cloud installation includes an infrastructure bootstrap phase, but the resulting environment can be recreated and torn down without manual infrastructure steps.

---

## 30. Cloud Runtime Image Promotion

### Decision

Promote runtime images into GCP Artifact Registry before installing the GKE workload.

### Chosen

The cloud installation:

1. authenticates to Artifact Registry;
2. pulls the required source artifacts;
3. pushes them into the customer repository;
4. resolves the promoted private digests; and
5. injects those digests into the Helm deployment.

### Rejected

Allowing the GKE nodes to pull runtime images directly from public registries.

### Reason

The customer image boundary is part of the runtime security requirement, not simply a build-time preference.

### Verification

The final GKE workload was inspected and all application runtime images referenced the private Artifact Registry using immutable digests.

### Evidence

`verification/logs/private-registry-final-verification.txt`

`verification/image-verification.md`

---

## 31. Cloud Installation Sequence

### Decision

Keep cloud installation as a controlled end-to-end sequence behind `./install.sh cloud`.

### Chosen

The cloud installer performs:

1. Terraform initialization and apply.
2. GKE credential setup.
3. Artifact Registry authentication.
4. Runtime image promotion.
5. Private digest resolution.
6. Customer egress CA and certificate generation.
7. Namespace and Secret/ConfigMap creation.
8. NetworkPolicy application.
9. Ingress configuration.
10. Admission policy application.
11. Helm rendering validation.
12. Helm installation.
13. Application verification.
14. Customer egress verification.

### Rejected

Separating these steps into undocumented manual operator actions.

### Reason

The customer platform team should have one reproducible installation path from an empty target environment to a verified deployment.

### Verification

The GKE deployment reached a deployed Helm state and the application returned the expected response.

---

## 32. Cloud Workload Verification

### Decision

Treat the cloud deployment as complete only after verifying workload, image, policy, ingress, and egress state together.

### Verified

The GKE target was verified for:

- deployed Helm release;
- Cap Web availability;
- Media Server availability;
- final Cap Pod state;
- final egress proxy Pod state;
- final NetworkPolicy state;
- final admission policy state;
- private digest-pinned runtime images;
- ingress behavior; and
- explicit egress denial.

### Evidence

- `verification/logs/cloud-application-serving.txt`
- `verification/logs/cloud-final-admission-policy.yaml`
- `verification/logs/cloud-final-cap-networkpolicies.txt`
- `verification/logs/cloud-final-cap-pods.txt`
- `verification/logs/cloud-final-egress-networkpolicies.txt`
- `verification/logs/cloud-final-egress-pods.txt`
- `verification/logs/cloud-ingress.txt`

---

## 33. Rollback Strategy

### Decision

Use Helm rollback rather than fix-forward during the change window.

### Chosen

Helm release history is used to identify the last known-good revision, and the deployment can be returned to that revision when a rollout fails.

### Rejected

Treating a failed customer release as an opportunity to make ad-hoc fixes directly in the live deployment.

### Reason

The customer change policy explicitly requires rollback during the change window.

### Verification

A deliberate invalid image revision was introduced during lifecycle testing and produced an `ImagePullBackOff` condition. The release was then returned to a known-good Helm revision.

The failed state and recovery are retained as evidence rather than relying solely on a clean upgrade test.

### Evidence

`verification/lifecycle/rollback/`

---

## 34. Uninstall and Reversibility

### Decision

Provide a dedicated uninstall path and verify removal of application-owned resources.

### Chosen

`./uninstall.sh` removes:

- the Cap Helm release;
- the `cap` namespace;
- the `customer-egress` namespace;
- cluster-scoped admission resources associated with the deployment; and
- targeted Cap persistent storage.

The customer private registry is treated as a separate bootstrap dependency and is not removed by application uninstall.

### Rejected

Leaving customer-egress infrastructure, admission resources, or persistent workload resources behind after uninstall.

### Reason

The assignment explicitly requires uninstall to leave nothing belonging to the deployment.

### Verification

The cloud uninstall evidence shows:

- Helm release absent;
- `cap` namespace absent;
- `customer-egress` namespace absent;
- admission policy absent;
- admission binding absent;
- remaining Cap/egress namespaces empty;
- associated CAP PVCs checked; and
- `RESULT=PASS`.

### Evidence

`verification/lifecycle/uninstall/cloud-uninstall-proof.txt`

`verification/lifecycle/uninstall/cloud-uninstall-terminal.txt`

---

## 35. Cloud Infrastructure Teardown

### Decision

Keep application uninstall and complete temporary cloud-environment teardown as separate lifecycle operations.

### Chosen

Application uninstall removes the Kubernetes workload and its associated deployment resources.

Terraform teardown removes the disposable cloud infrastructure.

### Rejected

Coupling workload uninstall directly to deletion of the entire cloud environment.

### Reason

The workload lifecycle and infrastructure lifecycle have different ownership and blast-radius boundaries.

### Verification

The temporary GKE environment was successfully removed and the unrelated existing cloud environment was preserved.

---

## 36. Intentional Baseline Scope

### Decision

Keep optional external functionality outside the baseline unless a concrete deployment requirement calls for it.

### Chosen

The baseline excludes:

- public AWS S3;
- Tinybird;
- Sentry;
- external OpenTelemetry exporters;
- Cap Cloud control-plane dependencies;
- Vercel-specific control-plane dependencies; and
- other optional SaaS integrations.

### Rejected

Adding external destinations merely because the upstream source contains optional integration code.

### Reason

The customer's core requirement is that nothing leaves the environment without explicit justification.

### Trade-off

Some optional vendor functionality is outside the baseline, but the resulting deployment has a substantially smaller and more auditable security boundary.

---

## 37. Evidence-First Engineering

### Decision

Treat verification artifacts as part of the deployment rather than as documentation after the fact.

### Chosen

The repository records:

- image inventory and verification;
- registry promotion;
- private registry pull behavior;
- RBAC authorization and denial;
- NetworkPolicy behavior;
- admission enforcement;
- customer egress TLS;
- proxy denial;
- cloud workload state;
- rollback behavior; and
- cloud uninstall behavior.

### Rejected

Relying only on statements such as "the network is default deny" or "the registry is private" without observable evidence.

### Reason

The assignment explicitly evaluates proof, not assertions.

### Evidence

The primary evidence tree is:

```text
verification/
├── egress/
├── logs/
├── lifecycle/
└── image-verification.md
```