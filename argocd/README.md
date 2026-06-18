# ArgoCD GitOps Layer (`argocd/`)

Continuous delivery for **eks-gitops-platform** is driven by [ArgoCD](https://argo-cd.readthedocs.io/)
using the **app-of-apps** pattern. A single *root* `Application` is applied by a human
(or a bootstrap pipeline) exactly once; from then on ArgoCD reconciles every other
workload — platform add-ons and the `demo-api` service — straight from Git. The cluster
state is whatever `main` says it should be, and drift is corrected automatically.

> Target cluster: `eks-gitops-platform-dev` / `eks-gitops-platform-prod` (EKS 1.30, `us-east-1`, multi-AZ).
> Source of truth: `https://github.com/charanvamsy26/eks-gitops-platform.git` @ `main`.

---

## Why app-of-apps?

Instead of registering a dozen `Application` objects by hand, we register **one**. The root
Application's source is a directory of *child* Application manifests (`argocd/apps/`). ArgoCD
renders that directory, sees the child Applications, and creates them — each of which then
points at its own chart/manifests. Adding a new component to the platform becomes a single
pull request that drops a new `Application` YAML into `argocd/apps/`; no `kubectl` and no
console clicks. This keeps onboarding, review, audit, and rollback entirely inside Git.

```
argocd/
├── install/                 # one-time cluster bootstrap (not managed by ArgoCD itself)
│   ├── namespace.yaml        #   argocd namespace
│   ├── kustomization.yaml    #   remote base -> upstream stable install manifests (pinned)
│   └── appproject.yaml       #   AppProject "eks-gitops-platform": source/destination/RBAC guardrails
├── bootstrap/
│   └── root-app.yaml         # the ONE Application you apply by hand (app-of-apps)
└── apps/                     # child Applications, reconciled by the root app
    ├── kube-prometheus-stack.yaml   # wave 0  (observability)
    ├── gatekeeper.yaml              # wave 0  (policy)
    ├── aws-load-balancer-controller.yaml  # wave 1 (ingress, optional)
    └── demo-api.yaml                # wave 2  (the workload)
```

---

## Bootstrap order

ArgoCD itself cannot be installed *by* ArgoCD (chicken-and-egg), so the `install/` step is the
only manual part. After that, everything flows from the root app.

1. **Install ArgoCD** into the `argocd` namespace from the pinned upstream manifests.
2. **Create the `eks-gitops-platform` `AppProject`** so all child apps inherit source/destination/RBAC
   restrictions (defense in depth — even a malicious PR can't point an app at an arbitrary repo
   or cluster).
3. **Apply the root app** (`bootstrap/root-app.yaml`). ArgoCD discovers `argocd/apps/`,
   creates the child Applications, and brings the platform up in wave order.

### Quick start

```bash
# 0. Point kubectl at the right cluster (dev shown; swap for prod)
aws eks update-kubeconfig --name eks-gitops-platform-dev --region us-east-1

# 1. Install ArgoCD (namespace + pinned upstream manifests)
kubectl apply -k argocd/install/

# 2. Wait for the control plane to be ready
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

# 3. Register the project guardrails + the root app (app-of-apps)
kubectl apply -f argocd/install/appproject.yaml
kubectl apply -f argocd/bootstrap/root-app.yaml

# 4. Watch the platform converge
kubectl -n argocd get applications -w

# 5. (optional) Grab the initial admin password and port-forward the UI
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:443
# open https://localhost:8080  (user: admin)
```

> The `appproject.yaml` is applied directly (not via the root app) on purpose: the root app and
> every child app reference `project: eks-gitops-platform`, so the project must exist *before* they sync.
> Keeping it in `install/` makes the dependency explicit and avoids a self-referential race.

---

## Sync waves

Add-ons must be healthy before the workload that depends on them syncs. ArgoCD orders work with
the `argocd.argoproj.io/sync-wave` annotation: **lower waves sync first**, and ArgoCD waits for a
wave to be Healthy before starting the next.

| Wave | Application                       | Namespace          | Why this wave |
|-----:|-----------------------------------|--------------------|---------------|
| `-1` | *(root app itself)*               | `argocd`           | Renders the children before anything else runs. |
| `0`  | `kube-prometheus-stack`           | `monitoring`       | CRDs (`ServiceMonitor`, `PrometheusRule`) must exist before workloads register metrics. |
| `0`  | `gatekeeper`                      | `gatekeeper-system`| Admission policy should be enforcing before app workloads are admitted. |
| `1`  | `aws-load-balancer-controller`    | `kube-system`      | Must run before any `Ingress`/`Service` that provisions an ALB/NLB. |
| `2`  | `demo-api`                        | `demo`             | The actual workload — installs last, once metrics, policy, and ingress are ready. |

Within a single Application, the same annotation orders individual resources (e.g. a `Namespace`
or `CustomResourceDefinition` in an earlier wave than the `Deployment` that uses it).

---

## Sync policy & self-healing

Every Application uses **automated sync** with:

- **`prune: true`** — resources deleted from Git are deleted from the cluster (no orphans).
- **`selfHeal: true`** — manual `kubectl edit` drift is reverted to the Git state.
- **`CreateNamespace=true`** — ArgoCD creates the target namespace with managed labels.
- **`ServerSideApply=true`** — avoids the client-side `last-applied` annotation blowing past the
  1 MB limit on large CRDs (kube-prometheus-stack and Gatekeeper ship very large CRDs).
- **Retry with backoff** — transient API/webhook errors don't wedge a sync.

### `ignoreDifferences`

Some controllers mutate their own objects after apply; reconciling those fields would leave
Applications perpetually `OutOfSync`. We ignore them where it is *correct* to do so:

- **Webhook `caBundle`** — Gatekeeper/cert-manager-style admission webhooks inject the CA at
  runtime; Git can't (and shouldn't) know it.
- **HPA-managed replicas** — when an HPA owns `spec.replicas`, Git must not fight it.
- **CRD `conversion.webhook.clientConfig.caBundle`** — same rationale as admission webhooks.

These are scoped narrowly (specific `group`/`kind`/`jsonPointers`) so real drift is still caught.

---

## Conventions enforced here

- **One Application per file** in `argocd/apps/` — clean diffs, easy ownership.
- **`repoURL: https://github.com/charanvamsy26/eks-gitops-platform.git`**, **`targetRevision: main`** everywhere.
- **Pinned chart versions** (`targetRevision` on Helm sources) — never float to "latest".
- **No `:latest` images** anywhere in the rendered output.
- **`finalizers: [resources-finalizer.argocd.argoproj.io]`** on every Application so deleting an
  Application cascades to its resources instead of orphaning them.

See each subdirectory's `README.md` for component-specific detail.
