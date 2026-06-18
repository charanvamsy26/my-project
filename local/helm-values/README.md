# LOCAL Helm value overlays (`local/helm-values/`)

These overlays adapt the **cloud** Helm values to a throwaway **kind** cluster
(`my-project-local`, Kubernetes 1.30, **no AWS**). They are applied as an extra
`-f` on top of each chart's base/cloud values and only change what is hostile to
a laptop: cloud-only integrations (ALB, IRSA, RDS, EBS) are turned off, while
every control Gatekeeper enforces (registry, non-`:latest` tag, resource
requests **and** limits, hardened securityContext, probes, ownership labels) is
kept so the manifests still pass policy locally.

| File | Layers on top of | What it does |
|------|------------------|--------------|
| `demo-api.local.yaml` | `kubernetes/charts/demo-api/values.yaml` (chart defaults) | DB-less, single-replica, port-forward-only demo-api |
| `kube-prometheus-stack.local.yaml` | `observability/kube-prometheus-stack/values.yaml` (cloud values) | Slim, PVC-free monitoring stack with a local Grafana password |

> Required tooling (`docker`, `kind`, `kubectl`, `helm`) and the full run-through
> (build image → `kind load` → install → port-forward) are documented in
> `local/README.md`. This file explains *what each overlay changes and why*.

---

## `demo-api.local.yaml`

Render to confirm it works:

```bash
~/.local/bin/helm template demo kubernetes/charts/demo-api \
  -f local/helm-values/demo-api.local.yaml --namespace demo
```

Install:

```bash
helm upgrade --install demo-api kubernetes/charts/demo-api \
  -f local/helm-values/demo-api.local.yaml -n demo --create-namespace
```

### Changes vs the chart/cloud values

| Key | Cloud default | Local value | Why |
|-----|---------------|-------------|-----|
| `replicaCount` | `2` | `1` | One pod is enough for a demo; less laptop memory. |
| `image.repository` | `ghcr.io/charanvamsy26/demo-api` | *(same)* | Restated for self-containment. |
| `image.tag` | `""` → appVersion | `local` | Matches the image side-loaded with `kind load`. Explicit, non-`:latest`, under `ghcr.io/charanvamsy26/` → passes **disallow-latest** + **allowed-registries**. |
| `image.pullPolicy` | `IfNotPresent` | *(same)* | Use the kind-loaded image; never pull `:local` (it isn't on GHCR). |
| `ingress.enabled` | `true` | **`false`** | ALB ingress needs the AWS LB Controller, absent on kind. Skipping the Ingress template also drops every `alb.ingress.kubernetes.io/*` annotation and the ACM cert ARN — i.e. **all AWS/ALB annotations are off**. Access is via `kubectl port-forward`. |
| `serviceAccount.annotations` | `{}` | `{}` | No IRSA `eks.amazonaws.com/role-arn`; IRSA is AWS-only. |
| `resources.requests` | `100m / 128Mi` | `50m / 64Mi` | Smaller footprint for a 1-node cluster. |
| `resources.limits` | `memory: 256Mi` **(no cpu)** | `cpu: 200m`, `memory: 128Mi` | **Critical:** the cloud values intentionally omit `limits.cpu`, but Gatekeeper's **require-resources** demands cpu+memory in *both* requests and limits. The `demo` namespace is **not** excluded by that constraint, so the local overlay **must add a CPU limit** or the pod is denied. |
| `autoscaling.enabled` | `true` | `false` | Avoid needing metrics-server on kind; honor the static replica count. |
| `podDisruptionBudget.enabled` | `true` | `false` | A single replica can't satisfy `minAvailable: 1` and would block node drains. |
| `databaseUrl` / `databaseUrlExistingSecret` | `""` / `""` | `""` / `""` | Explicitly DB-less: no RDS locally, so no `DATABASE_URL` env and no db Secret are rendered. App runs stateless. |
| `serviceMonitor.*` | enabled, `release: kube-prometheus-stack` | *(same)* | **Kept enabled** with the exact label the local Prometheus selects (`release: kube-prometheus-stack`). This is the scrape contract — see the stack overlay below. |
| `environment` | `dev` | `local` | Distinguishes laptop runs in dashboards/queries. |

### Deliberately **not** overridden (inherited, Gatekeeper-relevant)

`podSecurityContext`, `securityContext` (runAsNonRoot, drop `ALL` caps, no
privilege escalation, readOnlyRootFilesystem), and `livenessProbe` /
`readinessProbe` / `startupProbe` are left at the hardened chart defaults so
**require-security-context** and **require-probes** still pass. The standard
ownership labels (`app.kubernetes.io/name`, `/part-of`, `/managed-by: Helm`)
come from the chart's `labels` helper, satisfying **required-labels**.

### Verified

`helm template` renders 6 objects (NetworkPolicy, ServiceAccount, ConfigMap,
Service, Deployment, ServiceMonitor) and **no Ingress**. `helm lint` passes
(only the cosmetic "icon is recommended" info). `kubeconform -strict` reports
all schema-checked resources valid (ServiceMonitor is skipped — its CRD schema
isn't bundled, which is expected). Spot checks on the rendered Deployment:
`image: ghcr.io/charanvamsy26/demo-api:local`, `imagePullPolicy: IfNotPresent`,
resources with cpu+memory in **both** requests and limits, drop-`ALL` caps +
runAsNonRoot, the three probes present, no `DATABASE_URL`, `replicas: 1`; and
the ServiceMonitor carries `release: kube-prometheus-stack`.

---

## `kube-prometheus-stack.local.yaml`

This overlay is meant to be the **second** `-f`, layered on the cloud values so
the shared discovery contract (release-label selectors, dashboard sidecar) is
reused and only laptop-hostile bits change. The release name **must** stay
`kube-prometheus-stack` (the cloud `fullnameOverride` is inherited and demo-api's
ServiceMonitor is selected by `release: kube-prometheus-stack`).

```bash
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f observability/kube-prometheus-stack/values.yaml \
  -f local/helm-values/kube-prometheus-stack.local.yaml
```

### Changes vs the cloud values

| Key | Cloud value | Local value | Why |
|-----|-------------|-------------|-----|
| `prometheus.prometheusSpec.retention` | `30d` | `2d` | No 30-day SLO window needed on a laptop. |
| `prometheus.prometheusSpec.retentionSize` | `45GB` | `""` | No fixed-size PVC to protect once persistence is off. |
| `prometheus.prometheusSpec.storageSpec` | gp3 PVC (50Gi) | **`null`** | kind has no EBS CSI; a gp3 PVC would sit **Pending** forever. `null` (not `{}`) is required — Helm `coalesce` deep-merges maps, so `{}` would **keep** the inherited `volumeClaimTemplate`. `null` deletes the key → Prometheus uses emptyDir. |
| `alertmanager.alertmanagerSpec.storage` | gp3 PVC (5Gi) | **`null`** | Same reason/mechanism as above → emptyDir. |
| `grafana.persistence.enabled` | `true` (10Gi gp3) | `false` | No PVC; emptyDir is fine for a demo (annotations lost on restart). |
| `grafana.admin.existingSecret` | `grafana-admin-credentials` | `""` | The AWS-Secrets-Manager-synced Secret doesn't exist on kind. |
| `grafana.adminPassword` | *(unset; uses existingSecret)* | `"admin"` | **LOCAL-ONLY** throwaway credential so you can log in at `http://localhost:3000` with `admin` / `admin`. Never plaintext in dev/prod. |
| `grafana.grafana.ini.server.root_url` | `https://grafana.example.com` | `http://localhost:3000` | Grafana is reached via port-forward, not the ALB. |
| `grafana.grafana.ini.security.cookie_secure` | `true` | `false` | No HTTPS locally, so the login cookie must not require a secure context. |
| resource requests/limits (Prometheus, Alertmanager, Grafana) | larger | smaller | Fit a laptop (e.g. Prometheus 500m/2Gi → 100m/400Mi). |
| `prometheus.prometheusSpec.externalLabels` | `cluster: my-project`, `environment: dev` | `cluster: my-project-local`, `environment: local` | Tell laptop series apart from dev/prod. |
| `kubeControllerManager` / `kubeScheduler` / `kubeEtcd` `.enabled` | `false` (EKS hides them) | `true` | On kind the control plane is a local container and **is** scrapeable. |
| `defaultRules.rules.{etcd,kubeControllerManager,kubeScheduler}` | `false` | `true` | Re-enable the matching alert rules now that those targets exist. |

### Kept (inherited) — the scrape contract

`prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues: false` and
`serviceMonitorSelector.matchLabels.release: kube-prometheus-stack` are restated
(unchanged) so the local Prometheus scrapes **our** demo-api ServiceMonitor. The
Grafana **dashboard sidecar** stays enabled (watches for ConfigMaps labelled
`grafana_dashboard: "1"`, e.g. `demo-api-slo-burn.json`), so Git-managed
dashboards are auto-imported exactly as in the cloud.

### Verified

The two files were merged with real `helm template -f cloud -f local` (Helm
`coalesce` semantics). Result: `storageSpec` and `storage` resolve to `null`
(**no PVCs**), `grafana.adminPassword: admin` with `admin.existingSecret: ""`,
`grafana.persistence.enabled: false`, dashboard sidecar enabled,
`serviceMonitorSelectorNilUsesHelmValues: false` with the
`release: kube-prometheus-stack` selector, retention `2d`, local external
labels, and `kubeControllerManager.enabled: true`. An earlier `{}` form was
caught leaving the PVC in place and changed to `null`.
