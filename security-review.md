# Cap Security Review

## 1. Scope

This document records the security model and evidence for deploying Cap into a
regulated, shared Kubernetes environment.

The customer requirements driving this review are:

- No cluster-admin access for the FDE.
- Namespace-scoped deployment.
- Default-deny egress.
- All egress through the customer proxy.
- TLS interception by the proxy.
- Customer CA trust.
- Private registry only.
- Cluster admission controls.
- No-egress runners.
- No data leaving the customer network.
- No telemetry or license-check traffic.

The application source itself is not modified as part of the Kubernetes
deployment.

---

## 2. Security Boundaries

The deployment is separated into four main boundaries:

1. Kubernetes identity and authorization.
2. Network traffic between workloads.
3. Outbound traffic leaving the cluster/network.
4. Container image supply chain.

The Kubernetes application identity is intentionally more restricted than the
deployment identity.

The customer platform team remains responsible for cluster-wide controls.

---

## 3. Kubernetes RBAC

### 3.1 Application ServiceAccount

Cap application workloads use:

    ServiceAccount/cap

The ServiceAccount is configured with:

    automountServiceAccountToken: false

The application ServiceAccount is not bound to the deployment Role.

Reason:

Cap does not require Kubernetes API access for normal application operation.

Providing an API token would increase the attack surface without providing
application functionality required by the deployment.

Verification performed:

    kubectl get serviceaccount cap -n cap \
      -o jsonpath='automountServiceAccountToken={.automountServiceAccountToken}{"\n"}'

Observed:

    automountServiceAccountToken=false

Authorization checks for the application identity also returned `no` for:

- get Pods
- get Secrets
- get Nodes

Evidence:

    verification/logs/rbac-verification.txt

---

### 3.2 Deployment ServiceAccount

Deployment and namespace-scoped operational actions use:

    system:serviceaccount:cap:cap-deployer

The identity is bound through:

    Role/cap-deployer

    RoleBinding/cap-deployer

Both objects are namespaced to:

    cap

The Helm chart renders:

    Role

    RoleBinding

It does not render:

    ClusterRole

    ClusterRoleBinding

Verification:

    grep -E '^kind: (Role|RoleBinding|ClusterRole|ClusterRoleBinding)$' \
      /tmp/cap-rendered.yaml

Observed:

    kind: Role

    kind: RoleBinding

---

## 4. RBAC Permission Review

The deployment Role grants only permissions required to manage the Cap Helm
release and to perform namespace-scoped operational verification.

| API group | Resource | Verbs | Justification |
|---|---|---|---|
| core | configmaps | get, list, watch, create, update, patch, delete | Helm-managed configuration |
| core | secrets | get, list, watch, create, update, patch, delete | Helm-managed application secrets/configuration |
| core | services | get, list, watch, create, update, patch, delete | Application service lifecycle |
| core | serviceaccounts | get, list, watch, create, update, patch, delete | Required ServiceAccounts |
| core | persistentvolumeclaims | get, list, watch, create, update, patch, delete | Persistent workload storage |
| apps | deployments | get, list, watch, create, update, patch, delete | Cap web/media workloads |
| apps | statefulsets | get, list, watch, create, update, patch, delete | MySQL and MinIO workloads |
| batch | jobs | get, list, watch, create, update, patch, delete | MinIO setup Job |
| networking.k8s.io | ingresses | get, list, watch, create, update, patch, delete | Application ingress |
| networking.k8s.io | networkpolicies | get, list, watch, create, update, patch, delete | Application network controls |
| core | pods | get, list, watch | Deployment verification and diagnosis |
| core | events | get, list, watch | Namespace-scoped troubleshooting |
| core | pods/log | get | Namespace-scoped log inspection |

No permission is granted for:

- Nodes.
- Namespaces.
- ClusterRoles.
- ClusterRoleBindings.
- PersistentVolumes.
- Resources in other namespaces.

---

## 5. RBAC Verification Evidence

### Positive authorization

The following operations returned `yes` for `cap-deployer`:

    create deployments: yes

    patch secrets: yes

    create networkpolicies: yes

    get pods: yes

    get pods/log: yes

Commands used:

    DEPLOYER="system:serviceaccount:cap:cap-deployer"

    kubectl auth can-i create deployments --as="$DEPLOYER" -n cap

    kubectl auth can-i patch secrets --as="$DEPLOYER" -n cap

    kubectl auth can-i create networkpolicies --as="$DEPLOYER" -n cap

    kubectl auth can-i get pods --as="$DEPLOYER" -n cap

    kubectl auth can-i get pods/log --as="$DEPLOYER" -n cap

### Cluster-scope denial

The following operations returned `no`:

    get nodes: no

    create namespaces: no

    create clusterroles: no

    create clusterrolebindings: no

    get persistentvolumes: no

Commands:

    kubectl auth can-i get nodes --as="$DEPLOYER"

    kubectl auth can-i create namespaces --as="$DEPLOYER"

    kubectl auth can-i create clusterroles --as="$DEPLOYER"

    kubectl auth can-i create clusterrolebindings --as="$DEPLOYER"

    kubectl auth can-i get persistentvolumes --as="$DEPLOYER"

### Cross-namespace denial

The following operations returned `no`:

    get pods in kube-system: no

    get secrets in kube-system: no

    get pods in default: no

Commands:

    kubectl auth can-i get pods --as="$DEPLOYER" -n kube-system

    kubectl auth can-i get secrets --as="$DEPLOYER" -n kube-system

    kubectl auth can-i get pods --as="$DEPLOYER" -n default

### Application identity denial

The application ServiceAccount returned:

    automountServiceAccountToken=false

Authorization checks returned:

    app SA get pods: no

    app SA get secrets: no

    app SA get nodes: no

Full evidence:

    verification/logs/rbac-verification.txt

---

## 6. Container Security

The deployment deliberately applies non-root security controls.

The Cap web and media-server containers are configured with explicit non-root
UID/GID settings.

The MinIO setup Job is also explicitly hardened:

- runAsNonRoot: true
- runAsUser: 1000
- runAsGroup: 1000
- allowPrivilegeEscalation: false
- all Linux capabilities dropped
- seccomp profile: RuntimeDefault
- ServiceAccount token automount disabled

The MinIO setup Job initially failed because the non-root `mc` process attempted
to create its configuration directory under `/.mc`.

The first remediation was to set:

    HOME=/tmp

A second failure exposed an incorrect use of the `mc ready` command. The hook
was attempting to use a raw endpoint instead of a configured `mc` alias.

The final sequence is:

    mc alias set capminio

    mc ready capminio

    mc mb capminio/cap --ignore-existing

The corrected sequence was manually validated inside the failing hook pod.

The final Helm upgrade completed successfully as release revision 8.

Evidence:

    verification/logs/minio-setup-hook-failure.txt

---

## 7. NetworkPolicy

The namespace uses a default-deny ingress and egress model.

Required internal traffic is explicitly allowed.

Current workload relationships include:

- DNS egress.
- Web to MySQL.
- Web to MinIO.
- Web to media server.
- Media server to web.
- MinIO setup Job to MinIO.
- Corresponding required ingress rules.

Negative connectivity tests were also performed for traffic that should not be
allowed.

A real NetworkPolicy naming error was encountered during implementation:

An egress policy and an ingress policy were initially given the same object name,
causing one policy to replace the other.

The directional policies were then separated into unique object names.

Evidence:

    verification/logs/networkpolicy-media-to-web-incident.txt

The incident is retained because it demonstrates a real deployment constraint
and the resulting diagnosis rather than simply documenting the final state.

---

## 8. Egress Review

The customer requires default-deny outbound traffic and wants every required
external endpoint explicitly identified.

External paths investigated so far include:

### AWS S3

    FQDN: s3.amazonaws.com

    Port: 443

    Component: Cap web / S3 storage path

    Requirement: Not required for this self-hosted deployment

    What breaks without access: Public S3-backed storage path would not work

    Final state: Blocked

    Classification: Not required / replaced by internal MinIO

Evidence:

    verification/logs/s3-egress-investigation.txt

### Tinybird

    Component: Optional analytics path

    Runtime configuration: TINYBIRD_HOST not configured

    Final state: No baseline external access required

    Classification: Optional / disabled

Evidence:

    verification/logs/tinybird-egress-investigation.txt

### cap.so / Vercel

    Components: Optional rate limiting / Vercel integration paths

    Runtime configuration: Vercel integration not configured

    Final state: No baseline external access required

    Classification: Optional / disabled

Evidence:

    verification/logs/cap-so-vercel-investigation.txt

### Sentry / OpenTelemetry

    Components: tracing / telemetry integration

    Runtime configuration: external exporter endpoints not configured

    Final state: No baseline external telemetry access

    Classification: Disabled

Evidence:

    verification/logs/sentry-otel-egress-investigation.txt

The final environment still requires explicit proxy enforcement, allowlist
validation, denial-log capture, and full-deny air-gap verification before this
review can be considered complete.

---

## 9. Private Registry and Supply Chain

Customer workload images must come from the customer private registry.

Local customer-like registry:

    host.docker.internal:5001

The five deployed images are:

- Cap web
- Cap media server
- MySQL
- MinIO
- MinIO mc/setup image

All five are configured to use:

    host.docker.internal:5001

and all five are pinned by immutable `sha256` digest in the local deployment
values.

The rendered image policy assertion returned:

    PRIVATE_REGISTRY_DIGEST_ASSERTION_OK

The Kubernetes server-side dry run also passed.

The local registry was moved from HTTP to HTTPS with a customer-like CA.

The CA private key is kept outside the repository and registry certificate
material is excluded through `.gitignore`.

A Kubernetes image-pull test from the private registry succeeded after Moby
trust was configured.

One platform limitation remains documented: the local Apple Silicon image push
reported that only available single-platform content was pushed. This is not
claimed as full multi-architecture preservation.

The complete independent image verification remains a final submission task.

---

## 10. Data Crossing Boundaries

### Application traffic

The primary Cap application data paths are intended to remain internal to the
Kubernetes environment:

    Cap web → MySQL

    Cap web → MinIO

    Cap web → media server

    media server → Cap web

### Object storage

The self-hosted deployment uses internal MinIO rather than public S3.

### External telemetry

External telemetry is not configured in the current deployment.

### External SaaS integrations

Optional Tinybird, cap.so/Vercel, and external S3 paths were investigated and
are not required for the baseline self-hosted deployment.

A final proxy-controlled egress test remains required to prove that the
environment, rather than application convention, prevents unauthorized
external traffic.

---

## 11. Admission Control

### Control

The deployment uses Kubernetes-native:

    ValidatingAdmissionPolicy

and:

    ValidatingAdmissionPolicyBinding

The policy and binding are both named:

    cap-private-registry

### Security requirement

The policy enforces that every container image admitted into the `cap`
namespace comes from the approved private registry:

    host.docker.internal:5001/

The validation covers:

    spec.containers

    spec.initContainers

    spec.ephemeralContainers

This prevents an unapproved image from being introduced through a normal
container, init container, or ephemeral container.

### Enforcement

The policy uses:

    failurePolicy: Fail

The binding uses:

    validationActions:
      - Deny

The policy is scoped to the `cap` namespace using the namespace selector:

    kubernetes.io/metadata.name=cap

### Implementation issue and remediation

The first policy expression attempted to concatenate the container lists with
CEL `+`.

The Kubernetes API reported a type-checking warning because the required list
addition overload was not valid for the typed Pod fields.

The validation was rewritten to evaluate `containers`, `initContainers`, and
`ephemeralContainers` independently.

A subsequent server-side Helm dry run completed without expression warnings.

The corrected policy was installed successfully as Helm revision 10.

Live verification returned:

    observedGeneration=2

The binding returned:

    validationActions=["Deny"]

The expression warning check returned no warnings.

### Negative test — public main image

A test Pod using:

    busybox:1.36

was submitted to the `cap` namespace.

The API server rejected it with:

    Error from server (Forbidden)

The rejection explicitly referenced the:

    ValidatingAdmissionPolicy 'cap-private-registry'

policy.

A follow-up `kubectl get pod` returned `NotFound`, confirming that the Pod was
not created.

Result:

    PASS

### Positive test — private image

A test Pod using the private digest-pinned image:

    host.docker.internal:5001/cap/minio-mc@sha256:37d109dddbbb2c95873f5fc81ac93f37023264770fc580a7564148892087b1b7

was accepted.

Observed:

    pod/admission-private-test created

The container subsequently exited, but the admission result was successful
because the Kubernetes API accepted and created the Pod.

Result:

    PASS

### Negative test — public init-container bypass

A test Pod used:

- a compliant private image for the main container
- `busybox:1.36` for the init container

The API server rejected the request with the same private-registry policy
message.

A subsequent lookup confirmed that the Pod was not created.

Result:

    PASS

This demonstrates that a public init-container image cannot bypass the
private-registry admission control.

### Evidence

Full admission-control verification is archived in:

    verification/logs/admission-control-verification.txt

---

## 12. Customer Responsibility Boundary

The customer platform team owns cluster-wide controls.

These include:

- cluster-level admission policy
- shared-cluster infrastructure
- cluster networking
- customer registry infrastructure
- proxy infrastructure
- certificate authority
- cluster identity integration

The FDE deployment does not require cluster-admin privileges.

The deployment is intentionally designed to work within the namespace and
permissions granted to the FDE deployment identity.

---

## 13. Current Security Status

### Completed and verified

- Namespace-scoped RBAC.
- Positive RBAC authorization.
- Cluster-scope RBAC denial.
- Cross-namespace RBAC denial.
- Application ServiceAccount token isolation.
- Non-root workload hardening.
- Runtime securityContext restrictions.
- Default-deny workload NetworkPolicy baseline.
- Private registry HTTPS.
- Private-registry image pull.
- Digest-pinned private image rendering.
- External egress investigation.
- MinIO setup hardening and remediation.
- Kubernetes-native admission control.
- Private-registry admission enforcement.
- Public image rejection.
- Private image acceptance.
- Public init-container bypass rejection.

### Required before final submission

- Complete proxy implementation.
- TLS interception validation.
- Final explicit egress allowlist.
- Clean-install proxy denial log.
- Full-deny proxy air-gap test after installation.
- No-egress runner proof.
- Complete independent image verification.
- Deliberate rollback-from-half-applied-state proof.
- Complete uninstall/no-leftovers proof.
- Terraform cloud environment.
- Successful real-cloud deployment.
- Final zero-to-working installation recording.
- Final security/evidence audit.