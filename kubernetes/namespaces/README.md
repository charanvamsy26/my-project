# Namespaces

Declarative `Namespace` manifests for the **my-project** platform. They are the
foundational layer everything else lands in, so they are typically applied first
(by ArgoCD, as a sync-wave-0 / app-of-apps child, or via `kubectl apply` during
bootstrap).

Every namespace carries the standard project labels
(`project=my-project`, `app.kubernetes.io/part-of=my-project`, `managed-by`,
`environment`) plus two policy dimensions:

* **Pod Security Admission (PSA)** — `pod-security.kubernetes.io/{enforce,audit,warn}`.
* **Gatekeeper exemption** — `admission.gatekeeper.sh/ignore` for trusted
  control-plane namespaces that must not be gated by the policy webhook.

## Namespaces

| File                      | Namespace           | PSA enforce  | Gatekeeper exempt | Why |
| ------------------------- | ------------------- | ------------ | ----------------- | --- |
| `demo.yaml`               | `demo`              | `restricted` | no                | Application workloads (demo-api). Built to satisfy the strictest profile. |
| `monitoring.yaml`         | `monitoring`        | `privileged` | (platform)        | kube-prometheus-stack node-exporter needs host access; restricted would block it. |
| `gatekeeper-system.yaml`  | `gatekeeper-system` | `privileged` | **yes**           | Gatekeeper's own controllers — exempt so it can't deadlock itself. |
| `argocd.yaml`             | `argocd`            | `baseline`   | **yes**           | GitOps control plane; exempt to avoid bootstrap chicken-and-egg. |

## Why exempt some namespaces from Gatekeeper

OPA Gatekeeper enforces policy via a validating admission webhook. If that
webhook gated Gatekeeper's or ArgoCD's own pods, a misconfig could make the
cluster unable to repair itself (the webhook blocks the very components that fix
the webhook). Exempting these trusted platform namespaces is the standard,
safe pattern. Keep the exemption list as small as possible — application
namespaces like `demo` are **not** exempt.

## Apply

```bash
kubectl apply -f kubernetes/namespaces/
```

In normal operation these are reconciled by ArgoCD rather than applied by hand.

> Note: the `environment` label here defaults to `dev`. For a per-environment
> cluster (my-project-dev vs my-project-prod) overlay or patch this value so it
> matches the target cluster.
