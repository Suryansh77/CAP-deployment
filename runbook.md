# Cap Deployment Runbook

This runbook is written for an operator responsible for deploying and recovering the Cap Kubernetes workload in a constrained customer environment.

The deployment has two supported targets:

- local customer-like Kubernetes environment;
- GKE cloud environment.

The normal workload lifecycle is:

1. install;
2. verify;
3. upgrade when required;
4. rollback on failure;
5. uninstall when the workload is no longer required.

The customer change policy is rollback rather than fix-forward.

---

## 1. Purpose

The deployment is designed to be operated without cluster-admin access.

The normal deployment path uses:

```text
./install.sh local
./install.sh cloud
```

The local target uses Rancher Desktop/K3s.

The cloud target provisions its required infrastructure with Terraform and installs the workload with Helm.

The upstream Cap application is not modified.

The runbook assumes that the customer environment enforces:

- default-deny network policy;
- private registry usage;
- Kubernetes admission controls;
- namespace-scoped RBAC;
- controlled external egress; and
- customer TLS interception.

Do not weaken one of these controls to make an installation succeed.

---

## 2. Customer Access Model

The deployment is intended for a shared Kubernetes cluster where the FDE or deployment operator receives access to the Cap namespace but does not receive cluster-admin.

The normal identities are:

- application ServiceAccount;
- namespace-scoped deployment ServiceAccount.

The application ServiceAccount is not used for deployment administration.

The deployment ServiceAccount is bound only to the namespace-scoped Role required for the workload.

The customer egress proxy is operated separately in:

```text
customer-egress
```

The Cap workload is operated in:

```text
cap
```

Cluster-wide infrastructure remains the responsibility of the platform team.

Do not request or use cluster-admin as a normal troubleshooting shortcut.

---

## 3. Kubernetes Identities

### 3.1 Application ServiceAccount

The application uses a dedicated ServiceAccount.

Where Kubernetes API access is not required, token automount is disabled:

```text
automountServiceAccountToken: false
```

The application ServiceAccount should not be granted deployment privileges.

The purpose is to reduce the impact of a compromised application container.

### 3.2 Deployment ServiceAccount

Deployment operations use the namespace-scoped:

```text
cap-deployer
```

The identity is bound to the namespace-scoped `cap-deployer` Role and RoleBinding.

It is intended for:

- workload deployment;
- Secret management required by the install workflow;
- NetworkPolicy management within the namespace;
- Pod inspection;
- Pod log access; and
- other namespace-scoped operations explicitly required by the release.

It is not intended for:

- node inspection through privileged cluster APIs;
- namespace creation as a normal application operation;
- ClusterRole management;
- ClusterRoleBinding management;
- unrelated namespace access; or
- unrelated persistent-volume management.

---

## 4. Namespace-Scoped RBAC

The deployment must remain operable using namespace-scoped privileges.

Before a customer change window, verify the deployment identity:

```bash
kubectl auth can-i create deployments -n cap
kubectl auth can-i patch secrets -n cap
kubectl auth can-i create networkpolicies -n cap
kubectl auth can-i get pods -n cap
kubectl auth can-i get pods/log -n cap
```

These are expected to return:

```text
yes
```

Negative checks should be performed before deployment when practical:

```bash
kubectl auth can-i get nodes
kubectl auth can-i create namespaces
kubectl auth can-i create clusterroles
kubectl auth can-i create clusterrolebindings
kubectl auth can-i get persistentvolumes
kubectl auth can-i get pods -n kube-system
kubectl auth can-i get secrets -n kube-system
```

These are expected to return:

```text
no
```

The application ServiceAccount should also fail the tested Kubernetes API access checks.

Evidence is retained under:

```text
verification/logs/rbac-verification.txt
```

If a required namespace operation returns `no`, inspect the Role and RoleBinding before changing any permissions.

Do not grant cluster-admin to resolve an RBAC error.

---

## 5. Private Registry

The customer requirement is that Kubernetes runtime images originate from the approved private registry.

The runtime inventory covers:

- Cap Web;
- Cap Media Server;
- MySQL;
- MinIO;
- MinIO Client setup image; and
- customer egress proxy.

For the local target, the customer-like private registry is:

```text
host.docker.internal:5001
```

For the cloud target, runtime images are promoted to GCP Artifact Registry before installation.

Runtime images must use immutable digest references.

Verify rendered Helm images before installation:

```bash
helm template cap helm/cap -n cap -f <values-file>
```

Confirm that runtime images:

1. use the approved private registry;
2. contain immutable `sha256` digests; and
3. do not reference public registries directly.

The repository maintains image inventory and verification evidence under:

```text
verification/image-inventory.md
verification/image-verification.md
```

The identified build-stage images are separate from final runtime images. Build bases must not be mistaken for additional runtime workloads.

---

## 6. Helm Installation

### 6.1 Local installation

From the repository root:

```bash
./install.sh local
```

The local workflow configures the customer-like environment and installs the CAP workload.

Before installation verify:

```bash
kubectl config current-context
kubectl get nodes
kubectl get storageclass
kubectl get ingressclass
```

The expected local environment is Rancher Desktop/K3s with:

```text
Kubernetes v1.36.4
local-path
Traefik
Moby/Docker
```

### 6.2 Cloud installation

From the repository root:

```bash
./install.sh cloud
```

The cloud installer performs the infrastructure and workload bootstrap required for the GKE target.

The sequence includes:

1. Terraform initialization and apply.
2. GKE credential setup.
3. Artifact Registry authentication.
4. Runtime image promotion.
5. Private digest resolution.
6. Customer egress CA/TLS generation.
7. Namespace and Secret/ConfigMap creation.
8. NetworkPolicy application.
9. Ingress configuration.
10. Admission policy application.
11. Helm rendering validation.
12. Helm installation.
13. Application verification.
14. Customer egress verification.

Cloud installation should be treated as one controlled operation.

Do not manually skip image promotion, admission configuration, NetworkPolicies, or proxy setup just to make the application start.

### 6.3 Helm release inspection

Inspect the release with:

```bash
helm status cap -n cap
helm history cap -n cap
kubectl get pods -n cap -o wide
kubectl get svc -n cap
kubectl get ingress -n cap
```

If installation fails, diagnose the failing layer instead of immediately rerunning the entire operation.

---

## 7. Admission Control

The Cap namespace uses a Kubernetes-native:

```text
ValidatingAdmissionPolicy
ValidatingAdmissionPolicyBinding
```

to enforce the private-registry requirement.

The policy is fail-closed.

The relevant controls include:

```text
failurePolicy: Fail
validationActions: [Deny]
```

The policy covers:

- regular containers;
- init containers; and
- ephemeral containers.

### 7.1 Policy health verification

Check:

```bash
kubectl get validatingadmissionpolicy cap-private-registry -o yaml
kubectl get validatingadmissionpolicybinding cap-private-registry -o yaml
```

Verify the policy is present and enforcing `Deny`.

### 7.2 Public image rejection

A public image should be rejected by the admission layer before the Pod becomes a running workload.

The expected result is an API response containing:

```text
Forbidden
```

and the private-registry policy name.

A rejected Pod should not exist afterward.

### 7.3 Approved private image

A Pod using an approved private digest-pinned image should pass admission.

Admission acceptance is independent of whether the test container itself subsequently starts successfully.

### 7.4 Init-container bypass test

A workload with:

- compliant private main container;
- public init-container image

must still be rejected.

This proves that the registry control cannot be bypassed through an init container.

### 7.5 Policy troubleshooting

If a legitimate workload is rejected:

1. inspect the admission error;
2. inspect the rendered Helm manifest;
3. verify every container image, including init containers;
4. verify the registry hostname;
5. verify the digest reference;
6. re-run Helm rendering.

Do not weaken or disable the admission policy to make a deployment pass.

Admission evidence is retained under:

```text
verification/logs/admission-control-verification.txt
```

---

## 8. Deployment Verification

After installation, verify the release and workload:

```bash
helm status cap -n cap
kubectl get pods -n cap -o wide
kubectl get svc -n cap
kubectl get ingress -n cap
kubectl get networkpolicies -n cap
```

Verify the expected workloads are Ready.

Check application logs:

```bash
kubectl logs -n cap deployment/cap
kubectl logs -n cap deployment/cap-media-server
```

Verify runtime images:

```bash
kubectl get pods -n cap -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}{"  "}{.image}{"\n"}{end}{end}'
```

Expected runtime image properties:

- approved private registry;
- immutable digest;
- no direct public registry reference.

Verify the application endpoint responds with the expected application result.

The cloud verification evidence includes:

```text
verification/logs/cloud-application-serving.txt
verification/logs/cloud-final-cap-pods.txt
verification/logs/cloud-final-egress-pods.txt
verification/logs/cloud-final-cap-networkpolicies.txt
verification/logs/cloud-final-egress-networkpolicies.txt
verification/logs/cloud-final-admission-policy.yaml
verification/logs/cloud-ingress.txt
```

---

## 9. Customer Egress and TLS Verification

The Cap namespace uses default-deny egress.

External HTTPS traffic must use the customer egress proxy.

The proxy is deployed in:

```text
customer-egress
```

Verify the proxy:

```bash
kubectl get pods -n customer-egress -o wide
kubectl get svc -n customer-egress
kubectl get networkpolicies -n customer-egress
```

The proxy must retain:

```text
ssl_insecure=false
```

and use the customer upstream CA.

The verified customer-style CA is:

```text
Zamp Customer Egress CA
```

### 9.1 Allowed egress

Test an approved destination through the configured proxy path.

The authorized TLS test should demonstrate:

- connection through the proxy;
- customer CA presented on the intercepted connection;
- upstream certificate verification;
- successful HTTP response.

### 9.2 Denied egress

Test the known unallowlisted destination:

```text
example.com:443
```

Expected result:

```text
HTTP 403 Forbidden
```

The proxy log should contain:

```text
EGRESS DENY CONNECT host=example.com port=443
```

Evidence is retained under:

```text
verification/egress/
verification/logs/
```

### 9.3 Egress troubleshooting

When an external request fails:

1. Confirm the destination is actually required.
2. Check whether its FQDN and port are present in the approved allowlist.
3. Verify the workload is allowed to reach the proxy by NetworkPolicy.
4. Inspect proxy logs.
5. Confirm the proxy is using the correct upstream CA.
6. Confirm upstream TLS verification remains enabled.
7. Check whether the destination is being denied by policy.

Do not:

- add a wildcard Internet allow rule;
- disable TLS verification;
- bypass the proxy; or
- remove the default-deny policy as a diagnostic shortcut.

---

## 10. MinIO Setup

MinIO is initialized through the dedicated MinIO Client setup Job.

The setup sequence is:

1. configure the MinIO client alias;
2. wait for MinIO readiness;
3. create the bucket idempotently.

The setup Job uses:

- private registry image;
- immutable digest;
- non-root execution;
- dropped capabilities;
- RuntimeDefault seccomp;
- disabled ServiceAccount token automount; and
- a narrow network path to MinIO.

The non-root Job previously exposed two real failures.

First, the `mc` process attempted to create its configuration directory under `/.mc`.

The resolution was a writable temporary HOME:

```text
HOME=/tmp
```

Second, `mc ready` was initially invoked against a raw endpoint rather than a configured alias.

The final sequence uses the configured alias before readiness and bucket operations.

When troubleshooting MinIO initialization:

```bash
kubectl get pods -n cap
kubectl get jobs -n cap
kubectl describe job <job-name> -n cap
kubectl logs job/<job-name> -n cap
```

Then inspect the MinIO workload:

```bash
kubectl get pods -n cap -l app.kubernetes.io/name=minio
kubectl logs -n cap <minio-pod>
```

Do not make the MinIO setup Job privileged simply to bypass a filesystem or configuration failure.

---

## 11. Upgrade and Rollback

The customer change policy is rollback rather than fix-forward.

Before an upgrade:

```bash
helm history cap -n cap
helm status cap -n cap
kubectl get pods -n cap
```

Record the last known-good revision.

Use the repository's controlled Helm upgrade path rather than changing individual workload objects manually.

A typical Helm upgrade is:

```bash
helm upgrade cap helm/cap \
  --namespace cap \
  -f <values-file> \
  --rollback-on-failure \
  --timeout 10m
```

After the upgrade:

```bash
helm status cap -n cap
kubectl get pods -n cap
kubectl get events -n cap --sort-by=.lastTimestamp
```

### 11.1 Rollback procedure

Identify the last known-good revision:

```bash
helm history cap -n cap
```

Then roll back:

```bash
helm rollback cap <GOOD_REVISION> -n cap --wait --timeout 10m
```

Verify:

```bash
helm status cap -n cap
kubectl get pods -n cap -o wide
kubectl get ingress -n cap
```

Verify the application response before declaring recovery complete.

### 11.2 Half-applied release

If a release fails part-way through:

1. do not immediately apply ad-hoc changes;
2. inspect `helm status`;
3. inspect `helm history`;
4. inspect the newest Pods and Events;
5. identify whether admission, image pull, storage, hook execution, or application startup failed;
6. return to the last known-good revision when rollback is appropriate.

If a failed revision leaves a stale failed Pod behind, inspect its owner and the current controller state.

A stale failed Pod may need to be removed so that the controller can recreate the healthy replacement from the rolled-back specification.

The rollback evidence is retained under:

```text
verification/lifecycle/rollback/
```

The rollback test used a deliberate invalid image digest to create an `ImagePullBackOff` condition and then recovered to a known-good Helm revision.

This evidence demonstrates rollback behavior from a failed release state; it should not be interpreted as a claim that the same deliberate rollback test was performed on the GKE target.

---

## 12. Uninstall

The normal application uninstall entry point is:

```bash
./uninstall.sh
```

The uninstall procedure removes the application deployment resources and customer-egress resources associated with the installation.

It verifies removal of:

- `cap` namespace;
- `customer-egress` namespace;
- Cap Helm release;
- private-registry admission policy and binding;
- targeted Cap persistent storage.

After uninstall, verify:

```bash
kubectl get namespace cap
kubectl get namespace customer-egress
helm list -A
kubectl get validatingadmissionpolicy
kubectl get validatingadmissionpolicybinding
```

The expected state is that the Cap-specific resources are absent.

The customer private registry is a separate bootstrap dependency and is intentionally preserved by application uninstall.

### 12.1 Cloud uninstall evidence

The cloud uninstall workflow was executed and recorded.

Evidence:

```text
verification/lifecycle/uninstall/cloud-uninstall-proof.txt
verification/lifecycle/uninstall/cloud-uninstall-terminal.txt
```

The evidence records:

- Helm release removed;
- `cap` namespace removed;
- `customer-egress` namespace removed;
- admission policy removed;
- admission binding removed;
- remaining Cap/egress namespaces absent;
- associated CAP PVCs checked; and
- `RESULT=PASS`.

### 12.2 Complete cloud teardown

Application uninstall and infrastructure teardown are separate operations.

When removing the temporary cloud environment:

1. collect the required installation and verification evidence;
2. run the workload uninstall;
3. remove the temporary GKE infrastructure through the infrastructure lifecycle;
4. verify that the target cluster, networking, registry, and service-account resources are removed;
5. verify unrelated customer resources remain intact.

The temporary cloud environment was successfully returned to zero state while an unrelated existing GKE environment was preserved.

---

## 13. Break-Glass and Diagnostic Order

Break-glass access is for recovery or diagnostics that cannot be performed through the normal namespace-scoped workflow.

Any temporary privilege increase must be:

- explicitly authorized;
- limited to the required scope;
- time-bounded;
- recorded; and
- removed after use.

Do not use cluster-admin as a routine troubleshooting mechanism.

### Diagnostic order

For a failed deployment, inspect the layers in this order:

1. Helm status and rendered configuration.
2. Pod scheduling and Events.
3. Container status and logs.
4. Image pull and private-registry access.
5. Admission policy.
6. NetworkPolicies.
7. Customer egress proxy and allowlist.
8. Ingress.
9. Underlying cloud or cluster infrastructure.

### Common symptoms

**`ImagePullBackOff`**

Check:

```bash
kubectl describe pod <pod> -n cap
kubectl get events -n cap --sort-by=.lastTimestamp
```

Determine whether the issue is:

- incorrect registry;
- incorrect digest;
- registry TLS/trust;
- missing private image promotion; or
- runtime connectivity.

Do not replace a private image with a public image to make the Pod start.

**`Forbidden` during Pod creation**

Inspect the admission response.

Check:

```bash
kubectl get validatingadmissionpolicy cap-private-registry -o yaml
kubectl get validatingadmissionpolicybinding cap-private-registry -o yaml
```

Verify every main and auxiliary image uses the approved private registry.

**`ECONNREFUSED` between workloads**

Do not immediately assume that the destination process is unhealthy.

Check:

```bash
kubectl get pods -n cap
kubectl logs -n cap <destination-pod>
kubectl get networkpolicies -n cap
```

Verify both sides of the NetworkPolicy path.

A source egress rule alone may be insufficient; destination ingress also needs to permit the connection where the cluster's policy model requires it.

**External HTTPS returns `403`**

Check the proxy log and allowlist first.

An HTTP 403 from the proxy normally means the request reached the proxy but the destination was denied by policy.

**External HTTPS fails certificate validation**

Check:

- customer CA configuration;
- upstream trusted CA;
- proxy TLS configuration; and
- `ssl_insecure=false`.

Do not disable certificate validation as a workaround.

**Application unavailable after a release**

First inspect Helm history and determine whether the current revision is healthy.

During the customer change window, rollback to the last known-good revision before attempting an application-level fix-forward.

---

## Evidence Locations

The primary verification material is stored under:

```text
verification/
```

Important evidence includes:

```text
verification/image-inventory.md
verification/image-verification.md

verification/egress/
verification/logs/

verification/lifecycle/rollback/
verification/lifecycle/uninstall/
```

Cloud-specific evidence includes:

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

verification/lifecycle/uninstall/cloud-uninstall-proof.txt
verification/lifecycle/uninstall/cloud-uninstall-terminal.txt
```