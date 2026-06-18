# SLO definitions

Declarative, version-controlled Service Level Objectives for `my-project`.

## `slo.yaml` — the source of truth

Written in [Sloth](https://sloth.dev) (`prometheus/v1`). It defines a single,
honest SLO for the sample workload:

| Field         | Value                                                              |
| ------------- | ----------------------------------------------------------------- |
| Service       | `demo-api`                                                         |
| SLI           | availability — `good / valid` requests (non-5xx / all user reqs)   |
| Objective     | **99.9%**                                                          |
| Window        | rolling **30 days**                                                |
| Error budget  | 0.1% ≈ **43m 12s** full-downtime-equivalent / 30d                  |
| Alerting      | multi-window multi-burn-rate (page on fast burn, ticket on slow)  |

`/healthz`, `/readyz`, and `/metrics` are excluded from "valid" requests — they're
probe/scrape traffic, not user traffic.

## Why Sloth (not OpenSLO)

Sloth compiles directly to Prometheus-Operator `PrometheusRule` CRDs, which is
exactly how everything else in this repo is deployed, and its generated burn-rate
alerts are the canonical Google-SRE MWMB implementation. (OpenSLO is a fine vendor-
neutral schema but needs a separate compiler to reach the same CRDs.)

## Workflow

`slo.yaml` is authored by hand; the PromQL it compiles to is committed alongside it
in `../prometheus/rules/slo-rules.yaml` so on-call engineers can read the actual
rules without running a generator. After editing `slo.yaml`:

```bash
sloth validate -i slo.yaml
sloth generate -i slo.yaml -o ../prometheus/rules/slo-rules.yaml
# review the diff, then commit BOTH files together
```

`../prometheus/rules/slo-rules.yaml` is kept in sync by hand here so the repo is
useful even without the Sloth binary; the two must move together.
