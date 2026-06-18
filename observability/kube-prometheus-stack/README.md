# kube-prometheus-stack values

Helm values for the [`kube-prometheus-stack`](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
chart, the single bundle that gives us Prometheus (via the Prometheus Operator),
Alertmanager, Grafana, node-exporter, and kube-state-metrics.

## Purpose

`values.yaml` encodes the platform's monitoring decisions so they are reviewable and
reproducible across `dev` and `prod`:

- **Retention** — 30 days on disk, capped at 45 GB, aligned with the 30-day SLO window.
- **Storage** — Prometheus/Alertmanager/Grafana all use the encrypted EBS `gp3`
  StorageClass; nothing relies on ephemeral node storage.
- **Discovery contract** — Prometheus only adopts `ServiceMonitor`s, `PodMonitor`s and
  `PrometheusRule`s labelled `release: kube-prometheus-stack`. `demo-api`'s chart sets
  that label, so it is scraped automatically with zero Prometheus config changes.
- **Resource requests/limits** — every component is bounded so a query storm or WAL
  replay can't take down a node.
- **Grafana dashboard sidecar** — enabled, watching all namespaces for ConfigMaps
  labelled `grafana_dashboard: "1"`; this is how `grafana/dashboards/*.json` get loaded.
- **EKS realities** — control-plane components AWS manages (etcd, scheduler,
  controller-manager) are disabled so we don't ship `TargetDown` alerts that can never
  clear.

## How it's used

In `dev`/`prod` an ArgoCD `Application` (owned by the GitOps builder) references the
chart and this `values.yaml`. ArgoCD reconciles continuously with self-heal, so live
edits are reverted to match Git.

### Local reproduction (verification only)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f values.yaml
```

> The release name **must** be `kube-prometheus-stack` to match the
> `release: kube-prometheus-stack` discovery label used everywhere else.

## Secrets (never committed)

| Secret                                                           | Holds                  | Source in dev/prod        |
| --------------------------------------------------------------- | ---------------------- | ------------------------- |
| `grafana-admin-credentials`                                     | Grafana admin user/pw  | External Secrets ← AWS SM |
| `alertmanager-kube-prometheus-stack-alertmanager`               | `alertmanager.yaml`    | External Secrets ← AWS SM |

## Per-environment overrides

These are set as ArgoCD Application parameter overrides, not edited here:

| Value                                   | dev              | prod             |
| --------------------------------------- | ---------------- | ---------------- |
| `prometheus.prometheusSpec.replicas`    | 1                | 2                |
| `alertmanager.alertmanagerSpec.replicas`| 1                | 3                |
| `prometheus...externalLabels.cluster`   | `eks-gitops-platform-dev` | `eks-gitops-platform-prod`|
| `prometheus...externalLabels.environment` | `dev`          | `prod`           |
