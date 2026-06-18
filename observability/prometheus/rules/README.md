# Prometheus rules

`PrometheusRule` CRDs adopted by the Prometheus Operator. All three carry the
`release: kube-prometheus-stack` label so the Operator loads them (the discovery
contract — see `../../kube-prometheus-stack/values.yaml`).

| File                  | Group(s)                                   | Purpose                                                                 |
| --------------------- | ------------------------------------------ | ---------------------------------------------------------------------- |
| `recording-rules.yaml`| `demo-api.rates`, `demo-api.latency`       | Pre-aggregate demo-api RED metrics (rate, error ratio, p50/p95/p99).   |
| `alerts.yaml`         | `demo-api.alerts`, `kubernetes.*`, `monitoring.meta` | Symptom alerts: error rate, latency, crashloop, node NotReady, TargetDown, HPA maxed, rule-eval failures. |
| `slo-rules.yaml`      | `demo-api.slo.*`                           | 99.9%/30d availability SLO with multi-window multi-burn-rate alerts.    |

## RED metrics (recording-rules.yaml)

Recorded series follow `level:metric:operations`:

- `job:demo_api_requests:rate5m` — request throughput (req/s)
- `job:demo_api_errors:rate5m` — 5xx throughput
- `job:demo_api_error_ratio:rate5m` — error fraction in `[0,1]`
- `job:demo_api_request_duration_seconds:{p50,p95,p99}` — latency quantiles

All exclude probe/scrape paths (`/healthz`, `/readyz`, `/metrics`) so RED math
reflects user traffic only.

## SLO (slo-rules.yaml)

A real, error-budget-driven SLO for `demo-api`:

- **Objective:** 99.9% of valid requests succeed over a rolling **30 days**.
- **Budget:** 0.1% (~43m 12s of full-downtime-equivalent in 30d).
- **Alerting:** Google SRE **multi-window, multi-burn-rate** — a long and a short
  window must breach together, giving fast detection with few false pages.

| Severity | Burn | Long | Short | Routes to |
| -------- | ---- | ---- | ----- | --------- |
| critical | 14.4 | 1h   | 5m    | page      |
| critical | 6    | 6h   | 30m   | page      |
| warning  | 3    | 24h  | 2h    | ticket    |
| warning  | 1    | 72h  | 6h    | ticket    |

`slo-rules.yaml` is the readable, hand-auditable PromQL. The declarative source of
truth is `../../slo/slo.yaml` (Sloth), from which this file can be regenerated.

## Validate

```bash
promtool check rules recording-rules.yaml alerts.yaml slo-rules.yaml
```

> `promtool` requires `vector(...)` literals (used in `slo-rules.yaml` for the
> objective/budget metadata) — these are valid PromQL and pass `check rules`.
