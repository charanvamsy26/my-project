# `argocd/install/` — One-time cluster bootstrap

This directory holds the *only* manually-applied pieces of the GitOps stack. ArgoCD cannot
install or govern itself, so the control plane and its security boundary are created out-of-band,
exactly once per cluster. Everything afterward is reconciled by the root app (`../bootstrap/`).

## Contents

| File              | Purpose |
|-------------------|---------|
| `namespace.yaml`  | The `argocd` namespace, labelled with Pod Security Admission + project tags. |
| `kustomization.yaml` | Installs the ArgoCD control plane by overlaying our namespace onto the **pinned** upstream stable install manifests (`v2.13.2`). Bump the `?ref=` tag to upgrade. |
| `appproject.yaml` | The `my-project` `AppProject`: restricts source repos, destination namespaces, allowed resource kinds, and project RBAC. Every Application references `project: my-project`. |

## Usage

```bash
# 1. Install the control plane (namespace + pinned upstream manifests)
kubectl apply -k argocd/install/

# 2. Wait until the API server pod is ready
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

# 3. Create the project guardrails (must exist before any Application syncs)
kubectl apply -f argocd/install/appproject.yaml
```

Then apply the root app from `../bootstrap/root-app.yaml`.

## Why pin the upstream manifests?

`kustomization.yaml` references the upstream `install.yaml` by an immutable Git tag, not `HEAD`.
That keeps the control-plane version reproducible and makes upgrades a reviewable one-line diff.
Vendoring the ~25k-line manifest into the repo would bloat it and turn upgrades into merge hell.

## Production hardening checklist (not enabled in this reference)

- Swap the base for the **HA bundle** (`manifests/ha/install.yaml`) — 3 replicas of repo-server,
  Redis HA, and application-controller sharding.
- Front `argocd-server` with the **AWS Load Balancer Controller** ALB + ACM TLS, restrict to the
  corp CIDR, and disable the `--insecure` server flag.
- Wire **SSO/OIDC** and bind the `read-only` / `platform-admin` project roles to real IdP groups
  (placeholders `charanvamsy26:engineering` and `charanvamsy26:platform-sre` are in `appproject.yaml`).
- Store the initial admin secret rotation and enable **RBAC `policy.default: role:readonly`**.
