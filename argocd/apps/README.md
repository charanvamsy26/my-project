# `argocd/apps/` — Child Applications (managed by the root app)

Each file here is **one** ArgoCD `Application`. The root app (`../bootstrap/root-app.yaml`) renders
this directory and creates every Application it finds. Adding a platform component = add a YAML here
in a PR; removing one = delete the YAML (the root app prunes it). **One Application per file.**

## Components & sync order

| File | Component | Namespace | Wave | Source |
|------|-----------|-----------|:----:|--------|
| `kube-prometheus-stack.yaml` | Prometheus + Alertmanager + Grafana | `monitoring` | `0` | Helm repo chart + `observability/kube-prometheus-stack/values.yaml` (multi-source) |
| `gatekeeper.yaml` | OPA Gatekeeper admission control | `gatekeeper-system` | `0` | Helm repo chart + `policies/gatekeeper/values.yaml` (multi-source) |
| `aws-load-balancer-controller.yaml` | ALB/NLB ingress controller (optional) | `kube-system` | `1` | `eks-charts` Helm repo (inline values) |
| `demo-api.yaml` | Flask sample workload | `demo` | `2` | Local chart `kubernetes/charts/demo-api` + `values-<env>.yaml` |

**Why these waves:** observability and policy come first (wave 0) so their CRDs exist and admission
is enforcing; ingress is wave 1 so the controller is ready to provision ALBs; the `demo-api`
workload is wave 2 so it lands only after everything it depends on is Healthy. See the top-level
[`../README.md`](../README.md) for the full sync-wave rationale.

## Conventions (all files)

- `repoURL: https://github.com/charanvamsy26/eks-gitops-platform.git`, `targetRevision: main`.
- `project: eks-gitops-platform` (inherits the `AppProject` guardrails from `../install/appproject.yaml`).
- Automated sync with `prune: true` + `selfHeal: true`, `allowEmpty: false`.
- `ServerSideApply=true` everywhere (large CRDs exceed the client-side annotation limit).
- **Pinned** chart/image versions — never `latest`.
- `finalizers: [resources-finalizer.argocd.argoproj.io]` so deletion cascades to resources.
- `ignoreDifferences` only for controller-mutated fields (webhook `caBundle`, HPA-owned replicas).

## Path/namespace contract with other builders

These values must match the kubernetes/helm and observability builders **exactly**:

| Thing | Value |
|-------|-------|
| demo-api chart path | `kubernetes/charts/demo-api` |
| demo-api values files | `values.yaml`, `values-dev.yaml`, `values-prod.yaml` |
| demo-api namespace | `demo` |
| kube-prometheus-stack values | `observability/kube-prometheus-stack/values.yaml` |
| kube-prometheus-stack namespace | `monitoring` |
| gatekeeper values | `policies/gatekeeper/values.yaml` |
| gatekeeper namespace | `gatekeeper-system` |
| ALB controller namespace | `kube-system` |

## Multi-environment

`demo-api.yaml` targets **dev** (`values-dev.yaml`, cluster `eks-gitops-platform-dev`). For prod, copy the
file to a prod-scoped Application (e.g. via an overlay or a `demo-api-prod.yaml`) that uses
`values-prod.yaml` and the `eks-gitops-platform-prod` destination. Keeping dev/prod as separate Application
objects gives independent sync state, history, and rollback per environment.

## Optional component

`aws-load-balancer-controller.yaml` requires a real EKS cluster with **IRSA** — its ServiceAccount
must carry the IAM role ARN Terraform provisions (`arn:aws:iam::<account_id>:role/...`). The
`<vpc-id>` and `<account_id>` placeholders are documented in the file; template or overlay them per
environment before applying. Remove this file on a local/kind cluster where there is no ALB.
