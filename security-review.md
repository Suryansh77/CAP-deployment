# Cap Security Review

## 1. Scope

This document records the security model and verification evidence for deploying the self-hosted Cap application into a regulated, shared Kubernetes environment.

The design is based on the customer constraints described in the assignment:

- The FDE does not receive cluster-admin access.
- The workload operates within a customer-provided namespace.
- Network communication starts from a default-deny posture.
- External application egress is mediated by the customer egress proxy.
- The proxy performs customer-style TLS interception.
- The customer CA is trusted for the intercepted connection.
- Runtime images come from the customer-controlled private registry.
- Kubernetes admission enforces the private-registry requirement.
- Application identities use least privilege.
- Application data remains inside the customer environment unless an explicitly approved dependency requires external access.
- Baseline telemetry and license-check traffic are not configured.
- Application source is not modified for the Kubernetes deployment.

The security model is implemented through multiple independent controls rather than relying on application convention.

---

## 2. Security Boundaries

The deployment is divided into the following security boundaries:

1. Kubernetes identity and authorization.
2. Application and platform network traffic.
3. External egress through the customer proxy.
4. Runtime software supply chain.
5. Stateful application data.
6. Administrative and infrastructure lifecycle.

The primary Kubernetes workload runs in:

```text
cap
```

The customer egress proxy runs separately in:

```text
customer-egress
```

The customer platform team remains responsible for cluster-wide controls such as shared cluster infrastructure, identity integration, the customer registry service, and platform-level admission/network controls.

The FDE deployment is deliberately designed not to depend on cluster-admin privileges.

---

## 3. Kubernetes RBAC

### 3.1 Application ServiceAccount

Cap application workloads use:

```text
ServiceAccount/cap
```

The ServiceAccount is configured with:

```text
automountServiceAccountToken: false
```

The application ServiceAccount is not bound to the deployment Role.

### Reason

Cap does not require Kubernetes API access for normal application operation.

Providing an API token would increase the attack surface without providing application functionality required by the deployment.

### Verification

Observed:

```text
automountServiceAccountToken=false
```

Authorization checks for the application identity returned `no` for the tested Kubernetes resources, including:

- Pods;
- Secrets; and
- Nodes.

Evidence:

```text
verification/logs/rbac-verification.txt
```

---

### 3.2 Deployment ServiceAccount

Deployment and namespace-scoped operational actions use:

```text
system:serviceaccount:cap:cap-deployer
```

The identity is bound through:

```text
Role/cap-deployer
RoleBinding/cap-deployer
```

Both are namespaced to:

```text
cap
```

The Helm workload does not create a:

```text
ClusterRole
ClusterRoleBinding
```

### Reason

The customer provides namespace-scoped access on a shared cluster. The deployment must therefore operate entirely within the granted namespace boundary.

---

## 4. RBAC Permission Review

The deployment Role provides only the namespace-scoped permissions required to install, manage, and diagnose the Cap workload.

| API group | Resource | Verbs | Security justification |
|---|---|---|---|
| core | configmaps | get, list, watch, create, update, patch, delete | Helm-managed non-sensitive configuration |
| core | secrets | get, list, watch, create, update, patch, delete | Helm-managed sensitive configuration |
| core | services | get, list, watch, create, update, patch, delete | Application Service lifecycle |
| core | serviceaccounts | get, list, watch, create, update, patch, delete | Required workload identities |
| core | persistentvolumeclaims | get, list, watch, create, update, patch, delete | Stateful workload storage |
| apps | deployments | get, list, watch, create, update, patch, delete | Cap Web and Media Server |
| apps | statefulsets | get, list, watch, create, update, patch, delete | MySQL and MinIO |
| batch | jobs | get, list, watch, create, update, patch, delete | MinIO initialization |
| networking.k8s.io | ingresses | get, list, watch, create, update, patch, delete | Cap Web external entry point |
| networking.k8s.io | networkpolicies | get, list, watch, create, update, patch, delete | Explicit network isolation |
| core | pods | get, list, watch | Verification and diagnosis |
| core | events | get, list, watch | Namespace-scoped troubleshooting |
| core | pods/log | get | Namespace-scoped log inspection |

No permissions are granted for:

- Nodes;
- Namespaces;
- ClusterRoles;
- ClusterRoleBindings;
- PersistentVolumes; or
- resources in unrelated namespaces.

Broad built-in `edit`, `admin`, or cluster-admin access is intentionally avoided.

---

## 5. RBAC Verification Evidence

### Positive authorization

Verified operations for `cap-deployer` returned:

```text
create deployments: yes
patch secrets: yes
create networkpolicies: yes
get pods: yes
get pods/log: yes
```

### Cluster-scope denial

Verified operations returned:

```text
get nodes: no
create namespaces: no
create clusterroles: no
create clusterrolebindings: no
get persistentvolumes: no
```

### Cross-namespace denial

Verified operations returned:

```text
get pods in kube-system: no
get secrets in kube-system: no
get pods in default: no
```

### Application identity denial

The application ServiceAccount returned:

```text
automountServiceAccountToken=false
```

The tested application API operations returned:

```text
app SA get pods: no
app SA get secrets: no
app SA get nodes: no
```

### Evidence

```text
verification/logs/rbac-verification.txt
```

These tests demonstrate that the deployment identity can perform its intended namespace-scoped duties without receiving unrelated cluster privileges.

---

## 6. Container Security

The deployment applies explicit runtime hardening where compatible with the upstream images.

### Cap Web and Media Server

The workload uses explicit numeric non-root identities and:

```text
runAsNonRoot: true
allowPrivilegeEscalation: false
```

where required by the deployment security policy.

This was introduced after the original workload exposed an enforcement issue:

- Cap Web used a named user that could not satisfy the cluster's static non-root check.
- Media Server initially ran as root.

The images were not modified. Kubernetes security context was used to meet the platform requirement.

### MinIO setup Job

The hardened MinIO setup Job uses:

- non-root UID/GID;
- `runAsNonRoot: true`;
- `allowPrivilegeEscalation: false`;
- all Linux capabilities dropped;
- `RuntimeDefault` seccomp;
- disabled ServiceAccount token automount;
- writable temporary HOME for the non-root client.

The MinIO setup Job initially failed because `mc` attempted to create configuration below `/.mc`.

The remediation was:

```text
HOME=/tmp
```

A second failure exposed incorrect use of `mc ready` with a raw endpoint.

The final sequence configures an alias and then performs readiness and bucket operations using that alias.

Evidence:

```text
verification/logs/minio-setup-hook-failure.txt
```

No privilege escalation was introduced as a workaround.

---

## 7. NetworkPolicy

The Cap namespace begins with:

```text
default-deny ingress
default-deny egress
```

Only required communication paths are explicitly allowed.

### Allowed internal paths

- DNS;
- Ingress to Cap Web;
- Cap Web to MySQL;
- Cap Web to MinIO;
- Cap Web to Media Server;
- Media Server to Cap Web;
- MinIO setup Job to MinIO.

Where both directions are required, ingress and egress policy objects are represented independently.

### NetworkPolicy implementation failure

During implementation, an ingress and egress policy were initially assigned the same Kubernetes object name.

Because NetworkPolicy identity is namespace plus name, the later object replaced the earlier one.

The result was a real communication failure between Media Server and Cap Web.

The final implementation uses unique objects including:

```text
allow-media-server-to-web
allow-media-server-to-web-ingress
```

This incident is retained as evidence of the actual enforcement and troubleshooting process.

Evidence:

```text
verification/logs/networkpolicy-media-to-web-incident.txt
```

### Security property

MySQL, MinIO, and the Media Server are not exposed through the external ingress.

External application access is limited to Cap Web.

---

## 8. External Egress Security

The external egress model has two layers.

### Layer 1 — Kubernetes network isolation

Application workloads are permitted to reach the customer egress proxy only through explicit NetworkPolicy rules.

Direct unrestricted external access is not permitted.

### Layer 2 — Customer egress proxy

The proxy applies an explicit FQDN and port allowlist.

Each policy entry identifies:

- destination FQDN;
- port;
- component;
- why the destination is needed; and
- whether the dependency is installation-time or permanent runtime traffic.

The policy source is:

```text
policies/egress-allowlist.yaml
```

The proxy records denied CONNECT attempts.

This produces a security boundary that is both preventive and observable.

---

## 9. Customer TLS Interception

The customer egress proxy models the customer's TLS interception requirement.

The proxy terminates TLS and establishes the upstream connection while retaining upstream certificate verification.

The critical configuration is:

```text
ssl_insecure=false
```

Therefore upstream certificate verification is not disabled as a workaround.

The customer-style CA used for verification is:

```text
Zamp Customer Egress CA
```

The authorized TLS test was performed through the customer egress proxy and verified:

```text
PROXY_RESPONSE=HTTP/1.1 200 Connection established
TLS_AUTHORIZED=true
```

The intercepted certificate was signed by the customer-style CA and the controlled HTTPS endpoint returned:

```text
HTTP/1.0 200 OK
CUSTOMER_EGRESS_TLS_TEST_OK
```

This demonstrates that:

1. application HTTPS can pass through the interception boundary;
2. the customer CA is trusted;
3. the proxy participates in the TLS path; and
4. upstream certificate verification remains enabled.

Evidence is retained under:

```text
verification/egress/
verification/logs/
```

---

## 10. Egress Allowlist Review and Data Boundaries

The baseline deployment intentionally avoids unnecessary external data paths.

### AWS S3

```text
FQDN: s3.amazonaws.com
Port: 443
Component: S3 storage path
Classification: not required for baseline
State: blocked
Replacement: internal MinIO
```

The self-hosted deployment uses internal MinIO rather than public S3.

Evidence:

```text
verification/logs/s3-egress-investigation.txt
```

### Tinybird

Tinybird is an optional analytics integration and is not configured in the baseline.

No Tinybird host or token is configured and no external Tinybird destination is required for the baseline workload.

Evidence:

```text
verification/logs/tinybird-egress-investigation.txt
```

### Cap.so / Vercel

Optional Cap Cloud/Vercel-specific functionality is not required by the baseline.

No baseline access is granted to:

```text
cap.so
api.vercel.com
```

Evidence:

```text
verification/logs/cap-so-vercel-investigation.txt
```

### Sentry / OpenTelemetry

External Sentry and OTLP exporter traffic is not configured in the baseline.

No Sentry DSN or external OTLP exporter endpoint is required for the selected self-hosted deployment.

Evidence:

```text
verification/logs/sentry-otel-egress-investigation.txt
```

### Baseline data boundary

The intended application data paths are:

```text
Cap Web -> MySQL
Cap Web -> MinIO
Cap Web -> Media Server
Media Server -> Cap Web
```

Persistent application state therefore remains inside the customer Kubernetes environment.

The baseline does not intentionally send application data, telemetry, or license-check traffic to public external control-plane services.

---

## 11. Private Registry and Supply Chain

The runtime image boundary is enforced at both deployment and admission time.

### Runtime images

The runtime inventory includes:

- Cap Web;
- Cap Media Server;
- MySQL;
- MinIO;
- MinIO Client setup image; and
- customer egress proxy.

### Build-stage images

The upstream build process was also inspected for build-stage images, including:

- `oven/bun:1.4.0-alpine`;
- `oven/bun:1.4.0`; and
- `node:24-alpine`.

These are build dependencies and are not deployed as runtime workloads.

### Private registry

The local constrained environment uses:

```text
host.docker.internal:5001
```

The cloud deployment promotes the required runtime artifacts into GCP Artifact Registry.

Runtime workloads use immutable digest-pinned image references.

### Image verification

The local and cloud installation paths verify that runtime workloads reference the approved private registry rather than public registries.

The final cloud workload was inspected and its runtime images referenced the private Artifact Registry with immutable digests.

Evidence:

```text
verification/image-inventory.md
verification/image-verification.md
verification/logs/private-registry-promotion.txt
verification/logs/private-registry-final-verification.txt
```

### Private registry TLS

The initial local image pull exposed a transport mismatch:

```text
http: server gave HTTP response to HTTPS client
```

The registry was then moved to HTTPS with a customer-style CA rather than weakening the runtime with an insecure-registry exception.

Evidence:

```text
verification/logs/private-registry-pull-failure.txt
verification/logs/private-registry-pull-success.txt
```

The local Apple Silicon registry copy is single-platform; the implementation does not make a false multi-architecture claim for that local copy.

---

## 12. Admission Control

The private-registry requirement is independently enforced through Kubernetes admission.

### Control

The deployment uses:

```text
ValidatingAdmissionPolicy
ValidatingAdmissionPolicyBinding
```

named:

```text
cap-private-registry
```

The policy is scoped to the Cap namespace.

### Enforcement

The policy uses:

```text
failurePolicy: Fail
validationActions: [Deny]
```

The validation covers:

- `spec.containers`;
- `spec.initContainers`; and
- `spec.ephemeralContainers`.

This prevents a public auxiliary image from bypassing the main image restriction.

### Implementation correction

The initial CEL implementation attempted to concatenate typed container lists.

The Kubernetes API returned a type-checking warning because the list addition was not valid for those typed fields.

The policy was rewritten to evaluate each container collection independently.

The corrected version passed server-side validation without expression warnings.

### Negative verification

A public image:

```text
busybox:1.36
```

was rejected with:

```text
Error from server (Forbidden)
```

The rejected Pod was subsequently confirmed absent.

### Positive verification

A private digest-pinned image was accepted and the Pod was created successfully.

### Init-container bypass verification

A Pod with a private main image and public `busybox:1.36` init container was rejected.

The rejected Pod was subsequently confirmed absent.

### Live policy state

The corrected policy was observed with:

```text
observedGeneration=2
validationActions=["Deny"]
```

and no expression warnings.

Evidence:

```text
verification/logs/admission-control-verification.txt
verification/logs/cloud-final-admission-policy.yaml
```

---

## 13. Customer Egress Proxy Security

The customer egress proxy runs in:

```text
customer-egress
```

rather than the Cap application namespace.

The proxy is hardened with:

- non-root execution;
- dropped Linux capabilities;
- read-only root filesystem;
- RuntimeDefault seccomp;
- resource controls;
- disabled ServiceAccount token automount.

The proxy's upstream trust configuration uses the customer CA and retains upstream verification.

### Authorized path

The authorized TLS path was successfully exercised.

### Unauthorized path

A CONNECT request to:

```text
example.com:443
```

was rejected with:

```text
HTTP/1.1 403 Forbidden
```

and the proxy recorded:

```text
EGRESS DENY CONNECT host=example.com port=443
```

Evidence:

```text
verification/egress/cloud-proxy-denial.txt
verification/egress/cloud-proxy-denial-log.txt
verification/logs/proxy-denial.txt
verification/logs/proxy-denial-log.txt
```

### Direct bypass

The Cap Web workload was also tested without HTTP/HTTPS proxy environment variables.

A direct connection to the external destination failed with a connection-refused result.

This demonstrates that proxy configuration is not merely a convention; the Kubernetes network boundary independently prevents the workload from bypassing the proxy.

---

## 14. Cloud Security Verification

The cloud environment was provisioned through Terraform and the workload was installed through the cloud installer.

The cloud deployment verified:

- private runtime image promotion;
- private digest-pinned workload images;
- admission policy;
- final Cap NetworkPolicies;
- final customer-egress NetworkPolicies;
- final Cap Pod state;
- final customer-egress Pod state;
- ingress behavior;
- application availability; and
- customer egress denial behavior.

Cloud evidence is retained in:

```text
verification/logs/cloud-application-serving.txt
verification/logs/cloud-final-admission-policy.yaml
verification/logs/cloud-final-cap-networkpolicies.txt
verification/logs/cloud-final-cap-pods.txt
verification/logs/cloud-final-egress-networkpolicies.txt
verification/logs/cloud-final-egress-pods.txt
verification/logs/cloud-ingress.txt
verification/egress/cloud-proxy-denial.txt
verification/egress/cloud-proxy-denial-log.txt
```

The cloud application reached the deployed Helm state and returned the expected application response.

---

## 15. Lifecycle Security and Reversibility

### Rollback

The customer change policy is rollback rather than fix-forward.

A deliberate invalid image digest was used during lifecycle testing to create an `ImagePullBackOff` condition.

The release was then returned to the known-good Helm revision.

The rollback test was performed against the constrained/local Kubernetes deployment.

The architecture does not represent this test as a cloud rollback test.

Evidence:

```text
verification/lifecycle/rollback/
```

### Uninstall

The deployment provides:

```text
./uninstall.sh
```

The uninstall workflow removes the application workload, customer-egress resources, associated admission resources, and targeted application storage.

Cloud uninstall was executed and verified.

The recorded cloud evidence shows:

```text
Helm release absent
cap namespace absent
customer-egress namespace absent
ValidatingAdmissionPolicy absent
ValidatingAdmissionPolicyBinding absent
remaining Cap/egress namespaces empty
associated CAP PVCs checked
RESULT=PASS
UNINSTALL_COMPLETE
```

Evidence:

```text
verification/lifecycle/uninstall/cloud-uninstall-proof.txt
verification/lifecycle/uninstall/cloud-uninstall-terminal.txt
```

### Infrastructure teardown

Cloud infrastructure teardown is separate from application uninstall.

The disposable GKE environment was subsequently removed while the unrelated existing cloud environment was preserved.

This keeps the workload lifecycle and infrastructure lifecycle within separate blast-radius boundaries.

---

## Security Conclusion

The current deployment uses layered security controls across identity, network isolation, external egress, TLS interception, software supply chain, admission, and lifecycle management.

The most important security invariants are independently observable:

- application identities do not receive unnecessary Kubernetes API access;
- the deployment identity is namespace-scoped;
- default-deny network policy is the baseline;
- direct external bypass is blocked;
- external HTTPS is mediated by the customer proxy;
- upstream TLS verification remains enabled;
- runtime images are promoted into the private registry and digest-pinned;
- admission rejects unapproved image sources;
- baseline external telemetry and unnecessary SaaS dependencies are not configured; and
- the cloud workload can be cleanly uninstalled with recorded evidence.

The repository evidence under `verification/` is the source of truth for the observed security behavior.