# Service Level Objectives

The reliability contract for `demo-api`, expressed as SLIs, an SLO, and an error-budget policy. The machine-readable source of truth is the declarative Sloth spec at [`observability/slo/slo.yaml`](../observability/slo/slo.yaml); it compiles to hand-auditable PromQL in [`observability/prometheus/rules/slo-rules.yaml`](../observability/prometheus/rules/slo-rules.yaml).

## Why an SLO

SLOs turn "is it up?" into a measurable, agreed target with a finite **error budget**. The budget is what lets us move fast safely: as long as we're within budget, we ship; when the budget is gone, reliability work takes priority. This repo demonstrates the full Google-SRE loop — SLI definition, an objective, multi-window multi-burn-rate alerting, and an enforcement policy.

## Service Level Indicator (SLI)

**Availability** — the proportion of *valid* requests that succeed.

- **Good event:** an HTTP response with a non-5xx status.
- **Total (valid) events:** all requests **excluding** liveness, readiness, and scrape paths (`/healthz`, `/readyz`, `/metrics`) — probes and self-scrapes are not user traffic and must not skew the number.

Expressed over a window, from the Sloth spec:

```text
error_query = sum(rate(http_requests_total{service="demo-api", status=~"5..",
                       path!~"/healthz|/readyz|/metrics"}[window]))
total_query = sum(rate(http_requests_total{service="demo-api",
                       path!~"/healthz|/readyz|/metrics"}[window]))
SLI         = 1 - (error_query / total_query)
```

The recording rules also exclude probe/scrape paths and guard against `0/0` NaN, so the RED dashboards and the SLO math agree.

## Service Level Objective (SLO)

| Field | Value |
| --- | --- |
| Service | `demo-api` |
| SLI | Availability (non-5xx ratio of valid requests) |
| **Objective** | **99.9%** |
| Window | Rolling **30 days** |
| Error budget | 0.1% of valid requests |
| Budget as downtime-equiv. | ≈ **43m 12s** per 30 days |

## Error budget — burn math

The 0.1% budget can be spent quickly (a hard outage) or slowly (a low-grade elevated error rate). Multi-window multi-burn-rate (MWMB) alerting catches both while keeping false pages low — a short window confirms the problem is happening *now*, a longer window confirms it's *sustained*.

| Severity | Burn rate | Long window | Short window | Budget consumed if sustained |
| --- | --- | --- | --- | --- |
| **Page** | 14.4x | 1h | 5m | ~2% of 30d budget in 1h |
| **Page** | 6x | 6h | 30m | ~5% of 30d budget in 6h |
| **Ticket** | 3x | 24h | 2h | ~10% over a day |
| **Ticket** | 1x | 72h | 6h | steady slow drain |

These thresholds are emitted by Sloth and committed as readable PromQL; the page/ticket severities map directly to Alertmanager routing (`severity=critical` pages; SLO alerts thread into the dedicated SLO Slack channel).

## Error-budget policy

The budget governs the *pace of change*, not blame.

- **Budget healthy (> 25% remaining):** normal operations. Ship features; deploy freely.
- **Budget low (≤ 25% remaining):** caution. Prioritize reliability fixes; require extra review on risky changes; consider slowing rollouts.
- **Budget exhausted (≤ 0):** **feature-rollout freeze.** Only reliability, bug-fix, and rollback changes ship until the rolling-window budget recovers above threshold. The on-call/owning team drives recovery and a post-incident review.

Ownership is carried on every SLO series/alert via the `team: platform` / `owner: platform-sre` labels, so budget burn routes to the people who can act on it.

## What is explicitly out of scope

- **Liveness/readiness/scrape traffic** — excluded from the SLI by path filter.
- **Latency** has its own symptom alert (`DemoApiHighLatencyP99`, 500ms p99) but is **not** part of the availability SLO in this iteration. A latency SLO is a natural next addition (a second `slos:` entry in `slo.yaml`).

## Changing the SLO

Edit the source of truth, regenerate, and commit both files together so the spec and the deployed rules never drift:

```bash
# 1. edit observability/slo/slo.yaml
sloth validate -i observability/slo/slo.yaml
sloth generate -i observability/slo/slo.yaml -o observability/prometheus/rules/slo-rules.yaml
# 2. commit slo.yaml AND slo-rules.yaml in the same PR
```

ArgoCD then syncs the regenerated `PrometheusRule`, and the new objective is live.

## Where to look

- **Live compliance & budget:** Grafana `demo-api-overview` (SLO panel + 30d budget gauge + burn-rate panels).
- **Alert behavior:** [`observability/alertmanager/alertmanager.yaml`](../observability/alertmanager/alertmanager.yaml).
- **Incident response:** [`docs/runbook.md`](runbook.md) → `DemoApiAvailabilitySLO`.
