# deploy/ — Kustomize manifests for the auto-remediation controller

Apply with `kubectl apply -k .` (or render with `kustomize build .`). The
manifests span **two namespaces** by design.

| File                  | Kind            | Namespace   | Purpose |
| --------------------- | --------------- | ----------- | ------- |
| `namespace.yaml`      | Namespace       | —           | Creates `sre-tools` with the `restricted` Pod Security profile. |
| `serviceaccount.yaml` | ServiceAccount  | `sre-tools` | Identity the controller uses to call the K8s API (token mounted). |
| `role.yaml`           | Role            | `demo`      | Least-privilege grant on the **one** demo-api deployment. |
| `rolebinding.yaml`    | RoleBinding     | `demo`      | Binds the `sre-tools` SA into the `demo` Role (cross-namespace). |
| `deployment.yaml`     | Deployment      | `sre-tools` | The controller pod (1 replica, dry-run by default). |
| `kustomization.yaml`  | Kustomization   | —           | Entrypoint; pins the image tag; applies ownership labels. |

## Why `sre-tools` and not `monitoring`?

The project's Gatekeeper constraints
([`policies/gatekeeper/constraints/`](../../../policies/gatekeeper/constraints/))
**exclude the `monitoring` namespace** from the resources / security-context /
labels / registry / latest-tag rules — because kube-prometheus-stack pulls
upstream images and node-exporter needs host capabilities. Deploying the
controller there would mean it is *not* actually held to the policy bar.

We deploy into a dedicated, **non-excluded** `sre-tools` namespace instead, so the
controller is enforced against the **full** policy set and genuinely demonstrates
compliance. (`sre-tools` was the prompt's allowed alternative to `monitoring`.)

## Exact RBAC — what the controller can and cannot do

The controller's power is deliberately tiny. Full grant (`role.yaml`):

| apiGroup | resource               | resourceNames | verbs            | why |
| -------- | ---------------------- | ------------- | ---------------- | --- |
| `apps`   | `deployments`          | `demo-api`    | `get`, `patch`   | Read the deployment; patch its pod-template `restartedAt` annotation = the rolling restart. |
| `apps`   | `deployments/rollout`  | `demo-api`    | `create`         | Explicit "rollout" subresource path some tooling routes the restart through. |

**Not granted** (blast-radius minimisation): no `list`/`watch` (acts on one named
object, never enumerates), no `delete` (never deletes the deployment or pods), no
access to pods / replicasets / secrets / configmaps, no other namespace, and
**no ClusterRole** (namespaced Role only). `resourceNames: ["demo-api"]` pins even
the `demo` namespace grant to the single target — the controller cannot touch any
other workload in `demo`.

> The RoleBinding's subject is the SA in `sre-tools`; the Role + RoleBinding live
> in `demo` because RBAC is evaluated in the namespace of the object being acted
> on. Cross-namespace subject → role is fully supported by Kubernetes RBAC.

If you switch the controller to `MODE=rollback`, this K8s RBAC is unused (the
rollback goes through the Argo CD API instead) — you can leave it in place or
remove it; it grants nothing dangerous either way.

## Gatekeeper compliance checklist

Because `sre-tools` is **not** excluded, every constraint applies. The Deployment
satisfies all of them:

| Constraint (`policies/gatekeeper/constraints/`) | How this Deployment complies |
| ----------------------------------------------- | ---------------------------- |
| `K8sRequireResources` (deny)                    | `requests` + `limits` for both cpu and memory. |
| `K8sRequireSecurityContext` (deny)              | `runAsNonRoot: true`, `runAsUser: 10001`, `capabilities.drop: [ALL]`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `seccompProfile: RuntimeDefault`. |
| `K8sRequireProbes` (dryrun→deny)                | `livenessProbe` (exec: python is alive) + `readinessProbe` (exec: heartbeat file fresh < 90s). |
| `K8sAllowedRegistries` (deny)                   | Image `ghcr.io/charanvamsy/auto-remediation:0.1.0` matches the `ghcr.io/charanvamsy/` prefix. |
| `K8sDisallowLatestTag` (deny)                   | Explicit `:0.1.0` tag — never `:latest`. |
| `K8sRequiredLabels` (deny)                      | `app.kubernetes.io/name`, `app.kubernetes.io/part-of`, `app.kubernetes.io/managed-by: kustomize`. |
| `K8sBlockDefaultNamespace` (deny)               | Deploys to `sre-tools`, never `default`. |

`readOnlyRootFilesystem` is satisfied by mounting a writable `/tmp` `emptyDir`
(the only thing the controller writes: the heartbeat file).

## Going live (turning off dry-run)

The Deployment ships with `DRY_RUN=true`. After watching the JSON decision logs
and trusting them, set `DRY_RUN=false` (edit `deployment.yaml` env, or patch) and
re-apply. Everything else (cooldown, sustain gate, backoff) stays in force.

## Notes / placeholders to set for your cluster

- `PROM_URL` assumes the Service
  `kube-prometheus-stack-prometheus.monitoring.svc:9090`. Adjust if your
  Prometheus Service name differs.
- The image tag `0.1.0` is set in both `deployment.yaml` and the `images:` block
  of `kustomization.yaml` — bump the latter on release.
- A NetworkPolicy is intentionally **not** included here: `sre-tools` has no
  default-deny policy, so egress to Prometheus + the API server works out of the
  box. Add one (allow egress to `monitoring` :9090 and the API server) if your
  cluster runs default-deny.
