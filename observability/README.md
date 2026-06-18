# Observability — `my-project`

Production-grade observability layer for the **my-project** reference platform. This
directory contains everything required to monitor the platform and the sample
`demo-api` workload: metrics collection (Prometheus), visualisation (Grafana),
alerting (Alertmanager), and a real, error-budget-driven SLO for `demo-api`.

The stack is **kube-prometheus-stack** (Prometheus Operator + Prometheus +
Alertmanager + Grafana + node-exporter + kube-state-metrics), deployed via **ArgoCD**
into the `monitoring` namespace on the `my-project-dev` / `my-project-prod` EKS
clusters (Kubernetes 1.30, AWS `us-east-1`, multi-AZ).

---

## Why this layout

Observability is treated as a first-class, version-controlled product, not a set of
hand-clicked Grafana panels. Every dashboard, rule, and alert route lives in Git so
that it is reviewable, diffable, and reproducible across `dev` and `prod`. ArgoCD
reconciles it continuously, which means the monitoring system that watches our
platform is itself GitOps-managed and self-healing.

```
observability/
├── README.md                     # ← you are here: strategy + how it all fits
├── kube-prometheus-stack/
│   ├── README.md
│   └── values.yaml               # Helm values: retention, storage, scrape, Grafana, Alertmanager
├── prometheus/
│   └── rules/
│       ├── README.md
│       ├── recording-rules.yaml  # pre-aggregated RED metrics for demo-api
│       ├── alerts.yaml           # platform + workload alerts
│       ├── slo-rules.yaml        # 99.9% availability SLO, multi-window multi-burn-rate
│       └── burn-demo-rules.yaml  # convenience series for the error-budget burn demo
├── grafana/
│   └── dashboards/
│       ├── README.md
│       ├── demo-api-overview.json    # RED metrics + SLO / error budget
│       ├── demo-api-slo-burn.json    # watchable error-budget burn demo
│       └── kubernetes-cluster.json   # cluster health
├── alertmanager/
│   ├── README.md
│   └── alertmanager.yaml         # routing tree, Slack receiver, inhibition rules
└── slo/
    ├── README.md
    └── slo.yaml                  # declarative SLO (Sloth) — generates slo-rules.yaml
```

---

## The four pillars (what we collect and why)

| Pillar          | Tool                        | Where                                              |
| --------------- | --------------------------- | -------------------------------------------------- |
| Metrics         | Prometheus + node-exporter + kube-state-metrics | `kube-prometheus-stack/values.yaml`  |
| Dashboards      | Grafana (sidecar-loaded)    | `grafana/dashboards/`                              |
| Alerting        | Alertmanager → Slack        | `alertmanager/alertmanager.yaml`, `prometheus/rules/alerts.yaml` |
| SLO / budgets   | PromQL recording + alert rules | `prometheus/rules/slo-rules.yaml`, `slo/slo.yaml` |

We deliberately scope this repo to **metrics + alerting + SLOs**. Logs (Loki/CloudWatch)
and traces (Tempo/OTel) are valuable but out of scope for this reference layer; the
Grafana datasource model leaves room to add them later without restructuring.

---

## Metrics: the `demo-api` contract

The `demo-api` Flask service (port `8000`, namespace `demo`, image
`ghcr.io/charanvamsy26/demo-api:<tag>`) exposes Prometheus metrics at `GET /metrics`
via `prometheus_client`. The **metric and label contract below is shared with the
kubernetes/helm builder** — recording rules, alerts, SLOs, and dashboards all depend
on these exact names. Changing them requires changing both sides.

| Metric                                   | Type      | Labels                                         | Meaning                          |
| ---------------------------------------- | --------- | ---------------------------------------------- | -------------------------------- |
| `http_requests_total`                    | counter   | `namespace`, `service`, `path`, `status`       | total HTTP requests served       |
| `http_request_duration_seconds_bucket`   | histogram | `namespace`, `service`, `path`, `status`, `le` | request latency distribution     |
| `http_request_duration_seconds_count`    | histogram | `namespace`, `service`, `path`, `status`       | request count (for the histogram)|
| `http_request_duration_seconds_sum`      | histogram | `namespace`, `service`, `path`, `status`       | cumulative request seconds       |

Conventions:
- `service="demo-api"`, `namespace="demo"` on every series.
- `status` is the numeric HTTP status code as a string (`"200"`, `"503"`, …).
  A request is an **error** when `status =~ "5.."` (server-side fault — what the
  SLO holds us accountable for).
- `/healthz`, `/readyz`, and `/metrics` are excluded from SLO/RED math (probe and
  scrape traffic, not user traffic) via `path !~ "/healthz|/readyz|/metrics"`.

### How Prometheus discovers `demo-api`

The helm chart for `demo-api` ships a **`ServiceMonitor`** carrying the label
`release: kube-prometheus-stack`. Our Prometheus is configured (see
`serviceMonitorSelector` in `values.yaml`) to select ServiceMonitors with exactly
that label, so any new workload only needs to add the label to be scraped — no
Prometheus config change required. This is the **release-label discovery contract**
and it is identical on both sides.

---

## Dashboards

Dashboards are JSON files loaded automatically by the **Grafana dashboard sidecar**.
The sidecar watches for `ConfigMap`s labelled `grafana_dashboard: "1"` cluster-wide
and imports them, so adding a dashboard is "commit JSON + create a labelled
ConfigMap" — no Grafana UI, no manual import.

- **`demo-api-overview.json`** — RED method (Rate, Errors, Duration) for `demo-api`,
  plus live SLO compliance, 30-day error budget remaining, and burn-rate panels.
- **`kubernetes-cluster.json`** — cluster health: node readiness, CPU/memory
  saturation, pod restarts, and Prometheus target up-ness.

See `grafana/dashboards/README.md` for the ConfigMap pattern and validation.

---

## Alerting

`prometheus/rules/alerts.yaml` defines platform and workload alerts; Alertmanager
(`alertmanager/alertmanager.yaml`) routes them. Highlights:

- **Severity-based routing** — `critical` pages immediately with no group delay;
  `warning` batches into a less noisy Slack channel.
- **Inhibition** — a firing `critical` for a service suppresses the matching
  `warning`; a `TargetDown` suppresses the latency/error alerts that depend on
  that target (no point alerting on latency you can't measure).
- **Slack receivers** — channel + webhook are placeholders
  (`<SLACK_WEBHOOK_URL>`), wired through a Kubernetes Secret, never committed.

---

## SLIs, SLOs and error budgets

We run a single, honest SLO for the sample workload and treat it as the template for
real services.

| Term            | Definition for `demo-api`                                                        |
| --------------- | ------------------------------------------------------------------------------- |
| **SLI**         | Availability = `good requests / valid requests`, where a *good* request is any non-`5xx` response to user traffic. |
| **SLO**         | **99.9%** of valid requests succeed, measured over a **rolling 30-day window**.  |
| **Error budget**| `1 − 0.999 = 0.1%` of requests may fail in 30d — ~**43m 12s** of full-downtime equivalent. |

### Multi-window, multi-burn-rate alerting

Rather than alerting the moment a single request 500s, we alert on **how fast the
error budget is burning**, using the Google SRE multi-window multi-burn-rate method
(`slo-rules.yaml`). Two conditions must hold simultaneously (a long window to confirm
a sustained problem, a short window to confirm it's still happening), which gives
high precision (few false pages) and good recall (fast detection of real outages):

| Severity | Burn rate | Long window | Short window | Budget consumed if sustained | Meaning                  |
| -------- | --------- | ----------- | ------------ | ---------------------------- | ------------------------ |
| `critical` (page) | 14.4× | 1h    | 5m           | 2% in 1h                     | Budget gone in ~2 days   |
| `critical` (page) | 6×    | 6h    | 30m          | 5% in 6h                     | Budget gone in ~5 days   |
| `warning` (ticket)| 3×    | 24h   | 2h           | 10% in 24h                   | Budget gone in ~10 days  |
| `warning` (ticket)| 1×    | 72h   | 6h           | 10% in 72h                   | Slow, steady burn        |

The SLO is authored once declaratively in `slo/slo.yaml` (Sloth format) and the
generated PromQL lives in `prometheus/rules/slo-rules.yaml`, kept readable and
hand-auditable so an on-call engineer can reason about exactly what paged them.

---

## Error-budget burn demo

A purpose-built, *watchable* demo that makes the SLO math above visible end to end:
drive load, inject faults, and watch the 30-day error budget drain and the burn-rate
lines cross their page/ticket thresholds — then recover.

- **Dashboard:** [`grafana/dashboards/demo-api-slo-burn.json`](grafana/dashboards/demo-api-slo-burn.json)
  (Grafana UID `demo-api-slo-burn`) — error-budget remaining (%), fast (1h) vs slow
  (6h) burn rate against the 14.4× / 6× / 3× thresholds, request rate, 5xx error
  rate, and p99 latency. Built-in annotations mark the **fast/slow burn alerts**
  firing; Ctrl/Cmd-drag a region on any graph to label the **baseline → burn →
  recovery** phases live.
- **Recording rules:** [`prometheus/rules/burn-demo-rules.yaml`](prometheus/rules/burn-demo-rules.yaml)
  adds three thin convenience series the dashboard reads directly —
  `slo:error_budget:remaining_ratio30d`, `slo:burn_rate:fast` (1h), and
  `slo:burn_rate:slow` (6h). These are pure derivations of series already recorded
  in `slo-rules.yaml`; that file stays the single source of truth for the SLI/SLO.
- **Generate load:** [`../load-test/k6/`](../load-test/k6) drives steady traffic so
  the RED panels and burn-rate windows have data to chew on.
- **Inject faults:** [`../chaos/`](../chaos) (`chaos/scripts/` and
  `chaos/chaos-mesh/`) flips the app's chaos hooks — `CHAOS_ERROR_RATE`,
  `CHAOS_LATENCY_MS`, `CHAOS_OUTAGE`, or the token-guarded `POST /admin/chaos` —
  to push 5xx/latency through the normal instrumentation so they actually burn the
  budget.

Typical run: baseline (chaos off) → turn chaos on and watch *fast burn* cross 14.4×
within minutes while the budget gauge drains → turn chaos off and watch the lines
fall back below threshold and the budget stop draining.

---

## How it's deployed (kube-prometheus-stack via ArgoCD)

The monitoring stack is **not** applied with `helm install` by hand. ArgoCD's
app-of-apps (project `my-project`) owns it:

1. An ArgoCD `Application` (managed by the GitOps builder, not here) references the
   upstream `kube-prometheus-stack` Helm chart and **this directory's
   `values.yaml`** via a multi-source / valueFiles reference.
2. The `PrometheusRule` CRDs in `prometheus/rules/` and the dashboard ConfigMaps in
   `grafana/dashboards/` are applied into the `monitoring` namespace by the same
   ArgoCD app (or a sibling app), and picked up by the Operator and Grafana sidecar.
3. ArgoCD continuously reconciles: drift (someone edits a rule live) is reverted to
   match Git. `prune: true` + `selfHeal: true` are expected on the Application.

### Local / break-glass apply (verification only)

```bash
# Add the chart repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install with our values (release name MUST be kube-prometheus-stack to match the
# release-label discovery contract above)
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f kube-prometheus-stack/values.yaml

# Apply rules + dashboards
kubectl apply -n monitoring -f prometheus/rules/
kubectl apply -n monitoring -f grafana/dashboards/   # (as ConfigMaps; see that README)
```

ArgoCD is the source of truth in `dev`/`prod`; the commands above exist only to
reproduce the stack locally for testing.

---

## Validation

```bash
# Lint all PromQL rules (recording, alerts, SLO)
promtool check rules prometheus/rules/*.yaml

# Validate dashboard JSON
for f in grafana/dashboards/*.json; do jq -e . "$f" >/dev/null && echo "OK $f"; done

# Lint Alertmanager config
amtool check-config alertmanager/alertmanager.yaml

# Validate / regenerate SLO PromQL from the declarative spec
sloth validate -i slo/slo.yaml
sloth generate -i slo/slo.yaml -o prometheus/rules/slo-rules.yaml
```

---

## Conventions

- Kubernetes objects and filenames are **kebab-case**.
- Everything is tagged / labelled with `Project=my-project` and an `Environment`.
- No `:latest` image tags; pinned chart and image versions only.
- Secrets (Slack webhook, Grafana admin) are **referenced**, never committed —
  sourced from Kubernetes Secrets / External Secrets, documented inline.
