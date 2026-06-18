# Grafana dashboards

Version-controlled Grafana dashboards for `my-project`. They are loaded
automatically by the **Grafana dashboard sidecar** (enabled in
`../../kube-prometheus-stack/values.yaml`) — no manual UI import.

| Dashboard                  | UID                  | Shows                                                          |
| -------------------------- | -------------------- | ------------------------------------------------------------- |
| `demo-api-overview.json`   | `demo-api-overview`  | RED metrics (rate, errors, p50/p95/p99) + live SLO compliance, 30-day error budget remaining, and burn-rate panels. |
| `kubernetes-cluster.json`  | `kubernetes-cluster` | Cluster health: nodes ready/notready, CPU/memory saturation, pod restarts, scrape-target up-ness. |

Both reference only the pre-aggregated recording-rule series and standard
kube-state-metrics / node-exporter metrics, so panels stay fast.

## How the sidecar loads them

The sidecar watches the cluster for `ConfigMap`s labelled `grafana_dashboard: "1"`
and imports their JSON into the `my-project` Grafana folder. The dashboard JSON in
this directory is wrapped into ConfigMaps (one per file) and applied by ArgoCD.

Example ConfigMap wrapper (generated/applied by the GitOps layer):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-demo-api-overview
  namespace: monitoring
  labels:
    grafana_dashboard: "1"        # sidecar discovery label
  annotations:
    grafana_folder: my-project    # target folder
data:
  demo-api-overview.json: |-
    <contents of demo-api-overview.json>
```

Generate the wrappers from the raw JSON without hand-copying:

```bash
kubectl create configmap grafana-dashboard-demo-api-overview \
  --from-file=demo-api-overview.json -n monitoring \
  --dry-run=client -o yaml | \
  kubectl label --local -f - grafana_dashboard=1 -o yaml > /tmp/cm.yaml
```

## Variables

- `${datasource}` — Prometheus datasource (auto-provisioned by the chart).
- `${namespace}` — populated from `label_values(http_requests_total{service="demo-api"}, namespace)`;
  defaults to `demo`.

## Validate JSON

```bash
for f in *.json; do jq -e . "$f" >/dev/null && echo "OK $f"; done
```
