# Gatekeeper install (`gatekeeper/install/`)

Installs and configures the **OPA Gatekeeper control plane** on the `eks-gitops-platform`
EKS clusters (`eks-gitops-platform-dev`, `eks-gitops-platform-prod`, Kubernetes 1.30).

## Layout

| File | Purpose |
| ---- | ------- |
| `kustomization.yaml` | Pins the upstream Gatekeeper release (remote base) and layers our `Config` on top. |
| `config.yaml` | The singleton Gatekeeper `Config`: which kinds audit syncs, and the cluster-wide webhook exemptions. |

## Why a pinned remote base

The kustomization references upstream Gatekeeper at an explicit tag
(`?ref=v3.16.3` style pin via the raw release URL). This makes installs
**reproducible** and **reviewable**: bumping Gatekeeper is a one-line, reviewed PR,
and a re-sync never silently pulls an untested admission controller into the
cluster. We never track a moving branch for something that can reject every Pod.

> Confirm the pinned version supports your Kubernetes version before bumping. The
> pin here (v3.16.x) is validated against Kubernetes 1.27–1.30.

## Apply (local / break-glass)

In production this directory is reconciled by **ArgoCD** (sync wave 0). For local
clusters or break-glass:

```bash
# Control plane (namespace, CRDs, deployments, webhooks, RBAC, our Config)
kubectl apply -k policies/gatekeeper/install

# Wait for the webhook + audit to be Ready BEFORE applying any policy
kubectl -n gatekeeper-system rollout status deploy/gatekeeper-controller-manager
kubectl -n gatekeeper-system rollout status deploy/gatekeeper-audit
```

Then apply templates and constraints (in that order) from the sibling directories.

## The `Config` singleton

Gatekeeper reads exactly one `Config`, named `config` in `gatekeeper-system`.
Ours does two things — see the heavily-commented [`config.yaml`](config.yaml):

1. **`spec.sync.syncOnly`** — replicates selected resource kinds into OPA's cache so
   cross-object policies (e.g. "namespace must have a NetworkPolicy", "Ingress hosts
   must be unique") can see them. Cross-object rules over an un-synced kind silently
   evaluate against an empty set, so this list must include every kind our policies
   reason about beyond the object under review.
2. **`spec.match`** — the namespaces the admission webhook ignores **entirely**
   (`kube-system`, `gatekeeper-system`). This is the broadest exemption; everything
   else is scoped per-constraint via `excludedNamespaces`.

## Audit interval

Audit runs on the upstream default (60s) plus what we set via container args in the
pinned release. To change the cadence, override the `--audit-interval` arg on the
`gatekeeper-audit` Deployment with a strategic-merge patch in this kustomization
rather than editing upstream YAML.

## Uninstall (caution)

Deleting Gatekeeper removes the webhooks first; if you delete CRDs while
constraints exist you can wedge finalizers. Order: delete constraints → templates →
`kubectl delete -k .`.
