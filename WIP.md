# WIP — Pending Improvements

This file tracks follow-up work beyond the current submission baseline.

## Pending actions

### 1. Runner egress enforcement

Add end-to-end evidence that the deployment runner has no outbound path outside the approved customer environment. The current runner egress control is not yet fully validated on every environment.

### 2. Kubernetes portability

Reduce environment-specific assumptions around ingress, storage, networking, and container-runtime behavior so the deployment is easier to move across supported Kubernetes environments.

### 3. Cloud rollback validation

The rollback procedure has been validated in the constrained/local environment. A dedicated end-to-end rollback test on the cloud target remains a useful follow-up.

### 4. Additional lifecycle testing

Expand repeatable install/upgrade/rollback/uninstall testing across clean and partially applied states, with the same evidence standard used for the current submission.

These items are follow-up improvements and are intentionally kept separate from the primary submission documentation.