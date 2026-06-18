# load-test — demo-api reliability demo

This directory is the **load-testing layer** of the `my-project` EKS GitOps
platform. It exists to *prove the reliability story end-to-end*: it generates
traffic against `demo-api`, and — paired with the app's built-in chaos hooks —
shows the SLO either holding or visibly burning, lighting up the same metrics,
Prometheus SLO burn-rate alerts (`DemoApiAvailabilitySLO`) and Grafana panels
(`demo-api-overview`) that operate the real service.

Two scenarios, two outcomes:

| Scenario | File | What it proves | Expected k6 exit |
| --- | --- | --- | --- |
| **steady** | [`k6/steady.js`](k6/steady.js) | Under modest, steady load with chaos OFF, demo-api stays **inside** its SLO. | **PASS** (exit 0) |
| **burn**   | [`k6/burn.js`](k6/burn.js)   | Ramped load + server-side chaos on `/` **burns the error budget**; the SLO thresholds breach. | **FAIL** (non-zero) — *this is the point* |

> The burn scenario failing is the success criterion. Do not "fix" its
> thresholds to pass — they intentionally mirror the SLO that the run violates.

```
load-test/
├── README.md            # you are here
├── k6/
│   ├── steady.js        # green path: PASS
│   ├── burn.js          # red path: FAIL on purpose
│   └── lib/options.js   # shared BASE_URL/SLO/helpers
└── k8s/
    ├── README.md
    └── k6-job.yaml      # in-cluster Job + ConfigMap (scripts)
```

---

## The SLO contract these tests assert

Source of truth: [`observability/slo/slo.yaml`](../observability/slo/slo.yaml)
and the generated `observability/prometheus/rules/slo-rules.yaml`.

- **Availability:** 99.9% of *valid* requests succeed over a rolling 30-day
  window → **0.1% error budget**. "Valid" excludes `/healthz`, `/readyz`,
  `/metrics`; "bad" is any `5xx` (`status=~"5.."`).
- **Latency:** demo-api's histogram puts the **p99 SLO at 500 ms** (the `0.5s`
  bucket; `DemoApiHighLatencyP99` fires above it).

Both numbers live in one place — [`k6/lib/options.js`](k6/lib/options.js)
(`SLO.P99_LATENCY_MS = 500`, `SLO.MAX_ERROR_RATIO = 0.001`) — so the k6
thresholds and this doc cannot drift from the server-side SLO.

### How the scenarios map to the metric contract

The scripts drive the **`/` route**, which is exactly where demo-api's chaos
hooks live (`CHAOS_ERROR_RATE`, `CHAOS_LATENCY_MS`). Injected 500s and latency
flow through the app's normal `after_request` instrumentation, so they are
counted in `http_requests_total{service="demo-api",path="/",status="500"}` and
`http_request_duration_seconds_bucket{...}` — i.e. they burn the *real* error
budget the Prometheus SLO rules track. Watching `slo:error_budget...` or the
overview dashboard during a burn run shows the budget draining live.

---

## Prerequisites

- [`k6`](https://k6.io/docs/get-started/installation/) installed locally
  (`brew install k6`, or use the container image — see below).
- For in-cluster runs: `kubectl` pointed at the EKS cluster, with `demo-api`
  deployed in the `demo` namespace.
- For the **burn** scenario's server-side chaos: demo-api must be started with
  `CHAOS_ADMIN_TOKEN=<token>` (otherwise `/admin/chaos` is disabled and the run
  silently falls back to *pure-overload* mode).

---

## Running locally (port-forward)

Expose the in-cluster Service on localhost, then point `BASE_URL` at it:

```bash
# Terminal 1 — forward the Service (port 80) to localhost:8000.
# NOTE: the Helm chart names the Service after the release fullname. This demo
# assumes it is exposed as `demo-api` (install with --set fullnameOverride=demo-api,
# or substitute your actual Service name below).
kubectl -n demo port-forward svc/demo-api 8000:80
```

```bash
# Terminal 2 — steady scenario (expected PASS, exit 0).
BASE_URL=http://localhost:8000 k6 run k6/steady.js
```

```bash
# Terminal 2 — burn scenario (expected FAIL, non-zero exit).
# Needs demo-api started with CHAOS_ADMIN_TOKEN=devtoken for server-side chaos.
BASE_URL=http://localhost:8000 CHAOS_TOKEN=devtoken \
  CHAOS_ERROR_RATE=0.25 CHAOS_LATENCY_MS=800 k6 run k6/burn.js
```

If you omit `CHAOS_TOKEN`, `burn.js` runs in **pure-overload** mode — it just
ramps hard. On a small deployment, saturation alone usually breaches the p99
SLO; with chaos on, both latency *and* error thresholds breach.

### Pure-local dev (no cluster)

You can also run the app directly and load-test it:

```bash
# Terminal 1
CHAOS_ADMIN_TOKEN=devtoken APP_NAME=demo-api \
  python app/src/app.py            # serves on :8000

# Terminal 2
BASE_URL=http://localhost:8000 k6 run k6/steady.js
BASE_URL=http://localhost:8000 CHAOS_TOKEN=devtoken k6 run k6/burn.js
```

### Useful env knobs (both scenarios)

| Env | steady default | burn default | Meaning |
| --- | --- | --- | --- |
| `BASE_URL` | `http://localhost:8000` | same | Target base URL. |
| `RATE` | `20` | – | Steady requests/sec offered to `/`. |
| `DURATION` | `2m` | – | Steady-state duration. |
| `PEAK_RATE` | – | `150` | Burn peak requests/sec. |
| `CHAOS_TOKEN` | – | unset | If set, burn flips chaos on via `/admin/chaos`. |
| `CHAOS_ERROR_RATE` | – | `0.25` | Fraction of `/` returning 500 during burn. |
| `CHAOS_LATENCY_MS` | – | `800` | Added latency (ms) on `/` during burn (> 500ms SLO). |
| `PREALLOC_VUS` / `MAX_VUS` | `20`/`50` | `50`/`300` | k6 VU pool sizing. |

---

## Running in-cluster (k6 Job)

The scripts also run *inside* the cluster against the in-cluster Service via a
Kubernetes Job. Full details and the Gatekeeper-compliance notes are in
[`k8s/README.md`](k8s/README.md). Quick version:

```bash
# Applies BOTH the ConfigMap (scripts) and the Job. Defaults to STEADY.
kubectl apply -f k8s/k6-job.yaml
kubectl -n demo logs -f job/k6-steady
```

To run the **burn** scenario in-cluster, edit the Job's `command` to
`["k6","run","/scripts/burn.js"]` and uncomment the `CHAOS_TOKEN` env (sourced
from a Secret) — see `k8s/README.md`.

> **Image note:** the Job references `grafana/k6` through an **ECR/GHCR mirror**
> because the cluster's `K8sAllowedRegistries` Gatekeeper constraint forbids
> `docker.io`. Mirror the pinned tag once and replace `<account_id>` — see
> `k8s/README.md`.

---

## Makefile-style shortcuts

The repo's root [`Makefile`](../Makefile) is the standard entrypoint. Suggested
targets to add there (kept here as copy-paste so this dir stays self-contained):

```make
# ---- Load testing (load-test/) --------------------------------------------
BASE_URL ?= http://localhost:8000

.PHONY: load-steady
load-steady: ## Run the steady k6 scenario (expected PASS) against $(BASE_URL).
	BASE_URL=$(BASE_URL) k6 run load-test/k6/steady.js

.PHONY: load-burn
load-burn: ## Run the burn k6 scenario (EXPECTED FAIL — burns the SLO budget).
	BASE_URL=$(BASE_URL) CHAOS_TOKEN=$(CHAOS_TOKEN) k6 run load-test/k6/burn.js

.PHONY: load-steady-cluster
load-steady-cluster: ## Apply the in-cluster steady k6 Job and follow logs.
	kubectl apply -f load-test/k8s/k6-job.yaml
	kubectl -n demo wait --for=condition=ready pod -l app.kubernetes.io/name=k6-load-test --timeout=60s || true
	kubectl -n demo logs -f job/k6-steady
```

Run them as `make load-steady` / `make load-burn`
(`make load-burn CHAOS_TOKEN=devtoken` to enable server-side chaos).

---

## What to watch while a run is in flight

- **Grafana:** `demo-api-overview` dashboard — request rate, error %, p99
  latency. Steady = flat/green; burn = error % spikes, p99 crosses 500 ms.
- **Prometheus / Alertmanager:** `DemoApiAvailabilitySLO` (multi-window
  multi-burn-rate) pages on the burn run's fast budget consumption.
- **k6 summary:** the end-of-run table shows each threshold ✓ (steady) or ✗
  (burn) next to the measured `p(99)` and `slo_errors` rate.
