# demo-api

A small, production-shaped Python **Flask** service used as the reference
workload for the **eks-gitops-platform** platform. It is intentionally tiny but behaves
like a real service so it can exercise the full stack: **EKS** scheduling, the
**AWS Load Balancer Controller** (ALB Ingress), the **Prometheus Operator**
(ServiceMonitor scraping), **ArgoCD** GitOps delivery, and **OPA Gatekeeper**
policy enforcement.

Container image: `ghcr.io/charanvamsy26/demo-api:<tag>` (we never deploy
`:latest`). Kubernetes namespace: `demo`.

## Endpoints

| Method   | Path           | Purpose                                                              |
| -------- | -------------- | ------------------------------------------------------------------- |
| GET      | `/`            | Hello payload with service name/version and whether a DB is wired. Carries the chaos fault-injection hooks. |
| GET      | `/healthz`     | **Liveness** — process-only check. Never touches the DB or chaos.   |
| GET      | `/readyz`      | **Readiness** — probes the DB when `DATABASE_URL` is set; 503 if down (or on chaos outage). |
| GET      | `/metrics`     | Prometheus exposition (request count + latency histogram).          |
| GET/POST | `/admin/chaos` | Guarded runtime chaos toggle. **Disabled unless `CHAOS_ADMIN_TOKEN` is set.** |

### Liveness vs. readiness — why they differ

* `/healthz` only reports that the process is alive. If it fails, Kubernetes
  restarts the pod. It deliberately avoids downstream calls so a transient DB
  blip can't cause restart storms.
* `/readyz` reflects whether we can serve traffic. With a `DATABASE_URL`
  configured it runs a fast `SELECT 1`; on failure it returns **503** so the
  Service/ALB drains us from rotation, but the pod stays alive and recovers
  automatically. With no `DATABASE_URL`, the service is stateless and always
  ready.

## Configuration (environment variables)

| Variable             | Default      | Description                                            |
| -------------------- | ------------ | ------------------------------------------------------ |
| `APP_NAME`           | `demo-api`   | Logical service name (logs, metrics, hello payload).   |
| `APP_VERSION`        | `0.1.0`      | Reported version. Set to the image tag in CI.          |
| `DATABASE_URL`       | _(unset)_    | Optional Postgres DSN. Unset → stateless mode.         |
| `DB_CONNECT_TIMEOUT` | `2`          | Readiness DB probe timeout (seconds).                  |
| `LOG_LEVEL`          | `INFO`       | Root log level.                                        |
| `PORT`               | `8000`       | Port for local `python src/app.py` runs only.          |
| `CHAOS_ERROR_RATE`   | `0.0`        | Fault injection: fraction (`0.0`–`1.0`) of `/` requests that return **500**. Off by default. |
| `CHAOS_LATENCY_MS`   | `0`          | Fault injection: extra latency (ms) added to `/` requests. Off by default. |
| `CHAOS_OUTAGE`       | `false`      | Fault injection: when `true`, `/readyz` returns **503** so the pod goes NotReady (liveness still passes). |
| `CHAOS_ADMIN_TOKEN`  | _(unset)_    | Shared secret guarding `/admin/chaos`. **If unset, the endpoint is disabled (404).** |

## Observability

* **Logs**: structured single-line JSON to stdout (ts, level, msg, method,
  path, status, duration_ms, ...). Ready for Loki/CloudWatch.

### Metrics contract (canonical — owned by Prometheus + Grafana)

The **Prometheus rules** (`observability/prometheus/rules/*.yaml`) and the
**Grafana dashboard** (`observability/grafana/dashboards/demo-api-overview.json`)
are the **source of truth**. This app emits **exactly** the series they query —
do not rename a metric or label here without updating them first.

* `http_requests_total{service,path,status}` — **Counter**.
* `http_request_duration_seconds{service,path,status}` — **Histogram**
  (exposes `http_request_duration_seconds_bucket{service,path,status,le}` plus
  `_sum` / `_count`). Buckets:
  `0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0` s — the `0.5` s
  bucket aligns with the p99 latency SLO.

Label semantics:

| Label     | Value                                                                 |
| --------- | --------------------------------------------------------------------- |
| `service` | Constant **`demo-api`** (the value every rule selects on).            |
| `path`    | Matched **route template** (`/`, `/healthz`, `/readyz`, `/metrics`), not the raw URL, to bound cardinality. |
| `status`  | **Raw numeric HTTP code** as a string (`"200"`, `"404"`, `"500"`, `"503"`) — the rules match it with regexes like `status=~"5.."`, so it is NOT a class like `"5xx"`. |
| `le`      | Histogram bucket upper bound (added automatically by the histogram).  |

> The `namespace` label seen in the rules' `sum by (namespace, service)` clauses
> is **not** emitted by the app — Prometheus injects it from the Kubernetes
> scrape target at scrape time.

### Chaos / fault injection

Safe-by-default hooks let the chaos layer **burn the error budget on demand**.
Injected errors and latency still flow through the normal instrumentation, so
they **are counted** in the metrics above and show up on the SLO burn alerts and
dashboards.

* Configure statically via the `CHAOS_*` env vars (table above) — all off by
  default.
* Toggle at runtime via **`/admin/chaos`**, guarded by `CHAOS_ADMIN_TOKEN`:
  * `GET /admin/chaos` → returns the current state.
  * `POST /admin/chaos` with JSON `{"error_rate": 0.5, "latency_ms": 250, "outage": false}`
    (all fields optional) → updates and echoes the new state. `error_rate` is
    clamped to `[0,1]`; `latency_ms` to `>= 0`.
  * Auth: send the token as `X-Chaos-Token: <token>` **or**
    `Authorization: Bearer <token>`. Wrong/missing token → `401`. When
    `CHAOS_ADMIN_TOKEN` is unset the endpoint returns `404` (disabled).

```bash
# Make 30% of "/" requests fail and add 200ms latency, at runtime:
curl -s -X POST localhost:8000/admin/chaos \
  -H "X-Chaos-Token: $CHAOS_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"error_rate": 0.3, "latency_ms": 200}'

# Force the pod NotReady (drains it from the ALB without crashing):
curl -s -X POST localhost:8000/admin/chaos \
  -H "X-Chaos-Token: $CHAOS_ADMIN_TOKEN" \
  -d '{"outage": true}'
```

## Layout

```
app/
├── README.md            # this file
├── Dockerfile           # multi-stage, non-root, gunicorn :8000, HEALTHCHECK
├── .dockerignore
├── requirements.txt     # runtime deps
├── requirements-dev.txt # + pytest for CI/local
├── src/
│   └── app.py           # Flask app factory + routes + metrics + logging
└── tests/
    └── test_app.py      # pytest covering every route
```

## Local development

```bash
# from app/
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt

# run the dev server (Flask built-in, dev only)
python src/app.py
# -> http://127.0.0.1:8000/  /healthz  /readyz  /metrics

# run tests
pytest -q
```

To exercise stateful mode locally, point at any reachable Postgres:

```bash
DATABASE_URL=postgresql://user:pass@localhost:5432/demo python src/app.py
curl -i localhost:8000/readyz
```

## Build & run the container

```bash
# from app/
docker build -t ghcr.io/charanvamsy26/demo-api:0.1.0 .
docker run --rm -p 8000:8000 ghcr.io/charanvamsy26/demo-api:0.1.0
curl localhost:8000/healthz
```

The image runs **gunicorn** as a **non-root** user (uid 10001) and ships a
`HEALTHCHECK` that hits `/healthz`. In Kubernetes the root filesystem is mounted
read-only and all Linux capabilities are dropped — the app needs neither.

## Deploying

This service is deployed via the Helm chart at
`../kubernetes/charts/demo-api` and delivered through ArgoCD. See that chart's
README for values and environment overlays.
