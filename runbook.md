# Cap Deployment Runbook

## 1. Purpose

This runbook describes how Cap is deployed, verified, upgraded, rolled back,
and removed in a customer-like Kubernetes environment.

The target customer environment is a shared Kubernetes cluster where the
customer platform team owns cluster-scoped infrastructure and the Forward
Deployed Engineer (FDE) operates within an assigned application namespace.

The Cap application source is not modified as part of the Kubernetes
deployment.

---

## 2. Customer Access Model

The customer provides an existing namespace on the shared Kubernetes cluster.

The FDE does not require cluster-admin access.

The customer's platform team owns:

- cluster-wide infrastructure
- cluster-wide admission controls
- cluster networking infrastructure
- the customer private registry
- cluster-level policy and identity integration

The Cap deployment operates within the assigned application namespace.

The local customer-like environment may bootstrap cluster-level controls because
the assignment requires the customer constraints to be reproduced as code.

For the customer installation, the namespace is treated as platform-owned
infrastructure. The application deployment does not require permission to
create or delete the namespace.

---

## 3. Kubernetes Identities

### 3.1 Application ServiceAccount

Cap application workloads use the `cap` ServiceAccount.

The ServiceAccount is configured with:

    automountServiceAccountToken: false

The application ServiceAccount is not bound to the deployment Role.

This prevents Cap application workloads from receiving Kubernetes API
credentials that they do not require.

The application workload therefore has no intended Kubernetes API access.

### 3.2 Deployment ServiceAccount

Namespace-scoped deployment and operational actions use:

    system:serviceaccount:cap:cap-deployer

This identity is bound to:

    Role/cap-deployer

    RoleBinding/cap-deployer

Both resources are namespaced to `cap`.

The Cap chart does not render a ClusterRole or ClusterRoleBinding for this
identity.

---

## 4. Namespace-Scoped RBAC

The `cap-deployer` Role grants access only to resources required by the Cap
Helm release inside the `cap` namespace.

| API group | Resource | Verbs | Purpose |
|---|---|---|---|
| core | configmaps | get, list, watch, create, update, patch, delete | Manage Helm configuration |
| core | secrets | get, list, watch, create, update, patch, delete | Manage application configuration and secrets |
| core | services | get, list, watch, create, update, patch, delete | Manage service endpoints |
| core | serviceaccounts | get, list, watch, create, update, patch, delete | Manage required identities |
| core | persistentvolumeclaims | get, list, watch, create, update, patch, delete | Manage workload storage |
| apps | deployments | get, list, watch, create, update, patch, delete | Manage stateless workloads |
| apps | statefulsets | get, list, watch, create, update, patch, delete | Manage stateful workloads |
| batch | jobs | get, list, watch, create, update, patch, delete | Manage setup jobs |
| networking.k8s.io | ingresses | get, list, watch, create, update, patch, delete | Manage ingress |
| networking.k8s.io | networkpolicies | get, list, watch, create, update, patch, delete | Manage workload network controls |
| core | pods | get, list, watch | Deployment verification and diagnosis |
| core | events | get, list, watch | Namespace-scoped troubleshooting |
| core | pods/log | get | Namespace-scoped log inspection |

The Role deliberately does not grant permissions for:

- Nodes
- Namespaces
- ClusterRoles
- ClusterRoleBindings
- PersistentVolumes
- Resources in other namespaces

---

## 5. RBAC Verification

RBAC is verified with Kubernetes authorization checks rather than only by
inspecting the YAML.

### 5.1 Positive authorization checks

The following identity should be able to perform the required deployment and
diagnostic operations inside the application namespace:

    DEPLOYER="system:serviceaccount:cap:cap-deployer"

    kubectl auth can-i create deployments --as="$DEPLOYER" -n cap

    kubectl auth can-i patch secrets --as="$DEPLOYER" -n cap

    kubectl auth can-i create networkpolicies --as="$DEPLOYER" -n cap

    kubectl auth can-i get pods --as="$DEPLOYER" -n cap

    kubectl auth can-i get pods/log --as="$DEPLOYER" -n cap

Observed during verification:

    create deployments: yes

    patch secrets: yes

    create networkpolicies: yes

    get pods: yes

    get pods/log: yes

### 5.2 Cluster-scope denial checks

The same deployment identity must not have cluster-wide privileges:

    kubectl auth can-i get nodes --as="$DEPLOYER"

    kubectl auth can-i create namespaces --as="$DEPLOYER"

    kubectl auth can-i create clusterroles --as="$DEPLOYER"

    kubectl auth can-i create clusterrolebindings --as="$DEPLOYER"

    kubectl auth can-i get persistentvolumes --as="$DEPLOYER"

Observed during verification:

    get nodes: no

    create namespaces: no

    create clusterroles: no

    create clusterrolebindings: no

    get persistentvolumes: no

The warnings printed by `kubectl auth can-i` for these resources indicate that
the queried resource itself is cluster-scoped; the important authorization
result is `no`.

### 5.3 Cross-namespace isolation

The deployment identity must not access resources in other namespaces:

    kubectl auth can-i get pods --as="$DEPLOYER" -n kube-system

    kubectl auth can-i get secrets --as="$DEPLOYER" -n kube-system

    kubectl auth can-i get pods --as="$DEPLOYER" -n default

Observed during verification:

    no

    no

    no

### 5.4 Application ServiceAccount verification

The application ServiceAccount was checked independently:

    APP_SA="system:serviceaccount:cap:cap"

    kubectl get serviceaccount cap -n cap \
      -o jsonpath='automountServiceAccountToken={.automountServiceAccountToken}{"\n"}'

Observed:

    automountServiceAccountToken=false

Kubernetes API authorization checks also returned:

    app SA get pods: no

    app SA get secrets: no

    app SA get nodes: no

Complete RBAC verification is archived in:

    verification/logs/rbac-verification.txt

---

## 6. Private Registry

Customer workload images must come from the customer's private registry.

The local customer-like registry is:

    host.docker.internal:5001

The deployment is intended to use all five application images from this
private registry:

- Cap web
- Cap media server
- MySQL
- MinIO
- MinIO client/setup image

All five are pinned by digest.

The rendered deployment was explicitly checked to ensure that:

1. every workload image uses the private registry; and
2. every workload image uses an `@sha256:` digest.

The image-policy assertion passed with:

    PRIVATE_REGISTRY_DIGEST_ASSERTION_OK

Before a customer installation, render and inspect the chart:

    helm template cap helm/cap \
      --namespace cap \
      -f secrets/local-values.yaml \
      > /tmp/cap-rendered.yaml

    grep -E '^[[:space:]]+image:' /tmp/cap-rendered.yaml

The customer deployment must not fall back to a public registry.

---

## 7. Helm Installation

The customer namespace is expected to already exist.

For a namespace where the customer has granted the required deployment
permissions:

    helm upgrade --install cap helm/cap \
      --namespace cap \
      -f secrets/local-values.yaml \
      --rollback-on-failure \
      --timeout 10m

A disposable local environment may create its namespace during environment
bootstrap, but the customer FDE workflow must not depend on cluster-admin
permission to create the namespace.

---

## 7A. Admission Control

The deployment uses the Kubernetes-native `ValidatingAdmissionPolicy` and
`ValidatingAdmissionPolicyBinding` to enforce the private-registry invariant
within the Cap namespace.

The live policy and binding are:

    cap-private-registry

The policy is scoped to the `cap` namespace and uses:

    failurePolicy: Fail

The binding enforces:

    validationActions:
      - Deny

The policy validates image sources in:

    spec.containers
    spec.initContainers
    spec.ephemeralContainers

Every image must begin with the approved local/customer registry prefix:

    host.docker.internal:5001/

### 7A.1 Policy health verification

Check:

    kubectl get validatingadmissionpolicy cap-private-registry

Then:

    kubectl get validatingadmissionpolicy cap-private-registry \
      -o jsonpath='{.status.typeChecking.expressionWarnings}{"\n"}'

Expected:

    no expression warnings

Check the observed generation:

    kubectl get validatingadmissionpolicy cap-private-registry \
      -o jsonpath='observedGeneration={.status.observedGeneration}{"\n"}'

Observed after the final corrected deployment:

    observedGeneration=2

Check enforcement:

    kubectl get validatingadmissionpolicybinding cap-private-registry \
      -o jsonpath='validationActions={.spec.validationActions}{"\n"}'

Observed:

    validationActions=["Deny"]

### 7A.2 Public image rejection

A Pod using the public image:

    busybox:1.36

was submitted to the `cap` namespace.

The API server rejected the request with:

    Error from server (Forbidden)

The rejection explicitly referenced:

    ValidatingAdmissionPolicy 'cap-private-registry'

A follow-up lookup confirmed that the Pod did not exist.

This proves that an unapproved public main-container image is blocked before
Pod creation.

### 7A.3 Approved private image

A Pod using the private, digest-pinned image:

    host.docker.internal:5001/cap/minio-mc@sha256:37d109dddbbb2c95873f5fc81ac93f37023264770fc580a7564148892087b1b7

was accepted.

Observed:

    pod/admission-private-test created

The container later entered `Error`, but this does not invalidate the admission
test. The API server accepted and created the Pod.

The temporary test Pod was then deleted.

### 7A.4 Init-container bypass test

A test Pod used:

- a compliant private image for the main container
- `busybox:1.36` for an init container

The admission policy rejected the request.

The rejected Pod did not exist after the request.

This proves that a public init-container image cannot bypass the main-container
registry restriction.

### 7A.5 Policy implementation correction

The first policy expression attempted to concatenate the
`containers`, `initContainers`, and `ephemeralContainers` lists using CEL `+`.

The Kubernetes API reported a type-checking warning because the required list
addition overload was not valid for the typed Pod fields.

The policy was changed to evaluate each container list independently.

A server-side Helm dry run then completed without expression warnings.

The corrected policy was installed successfully as Helm revision 10.

### 7A.6 Evidence

Complete admission-control verification is archived in:

    verification/logs/admission-control-verification.txt

---

## 8. Deployment Verification

After installation or upgrade:

    helm status cap -n cap

    kubectl get pods -n cap

    kubectl get svc -n cap

    kubectl get ingress -n cap

    kubectl get pvc -n cap

The expected Cap workload components are:

- Cap web
- Cap media server
- MySQL
- MinIO

All application pods should reach `Running` and `Ready`.

Ingress verification in the current local environment:

    curl -i -H 'Host: cap.local' http://192.168.64.2/

The current deployment has historically returned the expected redirect toward
the Cap login endpoint.

---

## 9. MinIO Setup

The MinIO setup Job is a Helm post-install/post-upgrade hook.

The hook:

1. configures the `capminio` MinIO client alias;
2. waits for MinIO readiness;
3. creates the configured bucket idempotently;
4. exits successfully.

The setup Job is deliberately hardened:

- non-root UID/GID 1000
- `runAsNonRoot: true`
- `allowPrivilegeEscalation: false`
- all Linux capabilities dropped
- `RuntimeDefault` seccomp profile
- Kubernetes ServiceAccount token automount disabled
- writable `HOME` set to `/tmp`

This hardened configuration previously exposed two genuine deployment failures.

Those failures and their remediation are retained in the verification evidence.

---

## 10. Upgrade and Rollback

The customer change policy is rollback rather than fix-forward.

Use:

    helm upgrade cap helm/cap \
      --namespace cap \
      -f secrets/local-values.yaml \
      --rollback-on-failure \
      --timeout 10m

Inspect release history with:

    helm history cap -n cap

A real failed post-upgrade MinIO hook was encountered during implementation.

Helm successfully restored the previous working release.

The observed release sequence included:

- a failed upgrade caused by the MinIO setup hook
- automatic rollback to the previous working release
- a second failed upgrade while diagnosing the hook
- a subsequent successful upgrade after remediation

This behavior is retained as evidence because reversibility is an explicit
assignment requirement.

A deliberate rollback-from-half-applied-state test remains required before final
submission.

---

## 11. Uninstall

Remove the Helm release with:

    helm uninstall cap -n cap

Verify that application-owned resources are gone.

The shared customer namespace is platform-owned and must not be deleted by the
normal customer uninstall procedure.

The disposable local environment may remove the namespace during complete
environment teardown.

A complete no-leftovers verification remains required before final submission.

---

## 12. Break-Glass

Break-glass access remains a customer platform responsibility.

The FDIE should not bypass namespace-scoped controls by requesting or using
cluster-admin credentials.

Emergency changes must use the customer's approved namespace-scoped access
path and must be recorded as part of the change process.

---

## 13. Current Implementation Status

### Completed and verified

- Helm workload deployment
- private-registry HTTPS connectivity
- Kubernetes image pull from private registry
- private-registry digest rendering
- non-root workload hardening
- default-deny workload NetworkPolicy baseline
- namespace-scoped RBAC
- RBAC positive authorization tests
- RBAC cluster-scope denial tests
- RBAC cross-namespace denial tests
- application ServiceAccount isolation
- Helm rollback after a failed hook
- MinIO setup hook remediation
- ValidatingAdmissionPolicy
- private-registry admission enforcement
- public image rejection
- private image acceptance
- public init-container bypass rejection

### Remaining before final submission

- complete proxy implementation
- TLS interception
- explicit egress allowlist
- clean-install proxy denial log
- post-install full-deny air-gap proof
- no-egress runner
- complete independent image verification
- deliberate rollback-from-half-applied-state proof
- uninstall/no-leftovers proof
- Terraform cloud target
- clean installation on the real cloud target
- one-command end-to-end installation
- uncut zero-to-working installation recording
- final documentation and evidence audit