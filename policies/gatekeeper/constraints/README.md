# Gatekeeper Constraints (`gatekeeper/constraints/`)

Constraints are **instances** of the [`../templates/`](../templates/) — each one
selects which objects a rule applies to (`match`), supplies parameters, and sets the
`enforcementAction` (`deny` = block at admission, `dryrun` = audit/report only).

> Apply **after** templates. ArgoCD orders this via sync waves (templates = wave 1,
> constraints = wave 2).

## Enforcement matrix

| Constraint | Kind | Action | Matched scope | Why this action |
| ---------- | ---- | ------ | ------------- | --------------- |
| `required-labels.yaml` | `K8sRequiredLabels` | **deny** | Deployments/StatefulSets/DaemonSets | Labels are trivial to add; ownership is mandatory. |
| `disallow-latest-tag.yaml` | `K8sDisallowLatestTag` | **deny** | Pods | Mutable tags break reproducibility & rollbacks. |
| `require-resources.yaml` | `K8sRequireResources` | **deny** | Pods | BestEffort pods destabilize nodes. |
| `require-security-context.yaml` | `K8sRequireSecurityContext` | **deny** | Pods | Root + default caps is the top escape risk. |
| `allowed-registries.yaml` | `K8sAllowedRegistries` | **deny** | Pods | Supply-chain: no arbitrary public images. |
| `block-default-namespace.yaml` | `K8sBlockDefaultNamespace` | **deny** | workloads in `default` | Unowned namespace; always a mistake. |
| `require-probes.yaml` | `K8sRequireProbes` | **dryrun** | Pods | Surfaces legacy workloads; promote to deny after audit is clean. |
| `require-pdb.yaml` | `K8sRequirePDB` *(optional)* | **dryrun** | Deployments (≥2 replicas) | Cross-object cache race + commonly missing; deny would cause false positives. |

### Which are `deny` vs `dryrun`

- **deny (6):** required-labels, disallow-latest-tag, require-resources,
  require-security-context, allowed-registries, block-default-namespace. These are
  unambiguous, security/stability-critical, and `demo-api` + platform already comply.
- **dryrun (2):** require-probes, require-pdb. These commonly surface pre-existing
  debt. They report via audit so we can measure blast radius and fix offenders, then
  promote to `deny`. `require-probes` is expected to promote quickly (demo-api already
  passes); `require-pdb` stays dryrun longer due to the cross-object cache race.

### Promoting dryrun → deny

```bash
# 1. Confirm zero violations across dev + prod audit
kubectl get k8srequireprobes require-liveness-readiness-probes \
  -o jsonpath='{.status.totalViolations}{"\n"}'

# 2. Flip the action (in Git — never live-edit)
#    spec.enforcementAction: dryrun  ->  deny
# 3. Merge; ArgoCD syncs.
```

## Exemption strategy (recap)

Every `deny` constraint excludes system/platform namespaces via `excludedNamespaces`:

- `kube-system`, `kube-node-lease`, `kube-public` — Kubernetes internals.
- `gatekeeper-system` — never let Gatekeeper block its own control plane.
- `monitoring` — kube-prometheus-stack pulls **upstream** images (quay.io, docker.io)
  and node-exporter needs host capabilities; excluding it avoids fighting an upstream
  chart we don't own. Tighten this once those images are mirrored into ECR.

The broadest exemptions (`kube-system`, `gatekeeper-system`) are *also* set in the
cluster `Config` ([`../install/config.yaml`](../install/config.yaml)) so the webhook
ignores them entirely. See [`../../README.md`](../../README.md#exemptions) for the
full exemption model.

---

## demo-api compliance (verified by design)

`demo-api` (namespace `demo`, image `ghcr.io/charanvamsy26/demo-api:<tag>`, port 8000)
satisfies every `deny` constraint. Each rule below maps to the chart values the
demo-api Helm template renders:

| Constraint | What demo-api provides | Pass? |
| ---------- | ---------------------- | :---: |
| Required labels | `app.kubernetes.io/name: demo-api`, `app.kubernetes.io/part-of: my-project`, `app.kubernetes.io/managed-by: Helm` (set by Helm's standard labels helper) | ✅ |
| Disallow :latest | image is `ghcr.io/charanvamsy26/demo-api:<tag>` — explicit version tag, never `:latest`, never untagged | ✅ |
| Require resources | container sets `resources.requests.{cpu,memory}` **and** `resources.limits.{cpu,memory}` | ✅ |
| Security context | pod `runAsNonRoot: true`; container `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, not privileged | ✅ |
| Allowed registries | image prefix `ghcr.io/charanvamsy26/` is in the allow-list | ✅ |
| Block default ns | deploys to `demo`, not `default` | ✅ |
| Require probes *(dryrun)* | `livenessProbe` → `GET /healthz:8000`, `readinessProbe` → `GET /readyz:8000` | ✅ |
| Require PDB *(dryrun)* | optional; if a PDB ships it must select `app.kubernetes.io/name: demo-api`; single-replica deploys are below the `minReplicas: 2` threshold | ✅ |

> **Minimum compliant demo-api Pod spec** (the shape every constraint expects — the
> Helm chart must render at least this):
>
> ```yaml
> metadata:
>   labels:
>     app.kubernetes.io/name: demo-api
>     app.kubernetes.io/part-of: my-project
>     app.kubernetes.io/managed-by: Helm
> spec:
>   securityContext:
>     runAsNonRoot: true
>     seccompProfile: { type: RuntimeDefault }
>   containers:
>     - name: demo-api
>       image: ghcr.io/charanvamsy26/demo-api:1.0.0      # explicit tag, allowed registry
>       ports: [{ containerPort: 8000 }]
>       resources:
>         requests: { cpu: 50m,  memory: 64Mi }
>         limits:   { cpu: 250m, memory: 128Mi }
>       securityContext:
>         allowPrivilegeEscalation: false
>         readOnlyRootFilesystem: true
>         capabilities: { drop: ["ALL"] }
>       livenessProbe:  { httpGet: { path: /healthz, port: 8000 } }
>       readinessProbe: { httpGet: { path: /readyz,  port: 8000 } }
> ```
>
> The demo-api chart owner must keep its templates a superset of this. If a future
> chart change drops any field above, the corresponding `deny` constraint will reject
> the Pod — which is the intended guardrail.

## Local dry-run before merging

```bash
# Render demo-api and check it against the live constraints without applying:
helm template demo-api ./charts/demo-api | kubectl apply --dry-run=server -f -
```

A `server` dry-run runs the Gatekeeper webhook, so a non-compliant change fails here
instead of in the deploy pipeline.
