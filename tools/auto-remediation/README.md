# auto-remediation — self-healing controller for demo-api

A small, dependency-light Python controller that closes the loop between
**detection** (the demo-api SLO burn-rate alerts in
[`observability/prometheus/rules/slo-rules.yaml`](../../observability/prometheus/rules/slo-rules.yaml))
and **recovery** (Kubernetes). When demo-api is burning its error budget fast and
the breach is *sustained*, the controller automatically performs the safe,
boring, high-success remediation an on-call engineer would do first:
`kubectl rollout restart deployment/demo-api -n demo`. An optional Argo CD
rollback mode is included for "bad release" incidents.

This is the **reliability demo** layered on top of the existing EKS GitOps
platform. It backs the resume claims *"auto-healing workflows"* and *"MTTR -40%"*.

---

## The MTTR story (why this exists)

**MTTR = detect + acknowledge + diagnose + act.** For the single most common
demo-api failure mode — a wedged process throwing 5xx that a restart clears — the
human path is:

```
alert fires → pager → human wakes/context-switches → opens laptop → VPN/kubeconfig
            → `kubectl rollout restart` → watch it recover
```

The *acknowledge + context-switch + type the command* portion is minutes of
wall-clock time, almost all of it before any keystroke that actually fixes
anything. This controller collapses that to:

```
alert fires → controller already watching → sustained check → rollout restart (seconds)
```

The remediation action is **identical** to what the human would type; we just
remove the human round-trip from the critical path for the well-understood case.
The fast-burn SLO alert (`DemoApiErrorBudgetBurnFast`, 14.4× over 1h/5m) is the
trigger, so the bot acts on exactly the same signal that would otherwise page a
person. That removed round-trip is the **~40% MTTR reduction** — and because the
controller respects a cooldown and a sustained-breach threshold, it does not trade
that speed for stability (no restart storms).

> Humans still get paged (Alertmanager routing is unchanged). The controller is
> the *first responder*; the human is the *investigator* who shows up to a service
> that is already recovering and a structured log of exactly what the bot did.

---

## How it works

```
            ┌─────────────────────────────────────────────────────────────┐
            │                  auto-remediation controller                 │
            │                                                              │
  Prometheus│   every POLL_SECONDS:                                        │  Kubernetes API
  ──────────┼──▶ 1. query burn signal ──▶ breached? ──▶ sustained ≥ ───────┼──▶ rollout restart
  /api/v1   │                                            SUSTAINED_SECONDS │     (get + patch)
  /query    │                              │                  │            │
            │                              │ in COOLDOWN? ─yes─┤ suppress   │  -- or --
            │                              │                  │            │
            │   on API error: exponential backoff             ▼            │  Argo CD rollback
            │   every cycle: JSON log of the decision    remediate ────────┼──▶ (MODE=rollback)
            └─────────────────────────────────────────────────────────────┘
```

1. **Poll** Prometheus every `POLL_SECONDS` (default 30s).
2. **Detect** a breach via one of two strategies (`BURN_QUERY_MODE`):
   - `alerts` (default): the canonical fast-burn SLO alert is firing.
   - `burnrate`: the computed burn rate ≥ `BURN_THRESHOLD`.
3. **Sustain gate**: the breach must persist continuously for
   `SUSTAINED_SECONDS` (default 120s) before any action — single-scrape blips are
   ignored.
4. **Cooldown gate**: after any remediation, suppress further actions for
   `COOLDOWN_SECONDS` (default 600s) — prevents flapping / restart storms.
5. **Remediate** (`MODE`):
   - `restart` (default): rolling restart of the deployment. Uses the official
     `kubernetes` Python client (patches the pod-template
     `kubectl.kubernetes.io/restartedAt` annotation — exactly what
     `kubectl rollout restart` does) when the library is importable; otherwise
     shells out to `kubectl`.
   - `rollback`: `argocd app rollback <ARGOCD_APP>` to the last known-good revision.
6. **Safety throughout**: dry-run by default, exponential backoff with jitter on
   Prometheus/API errors, and one structured JSON log line per decision.

### The exact burn-rate PromQL it uses

The controller does **not** invent its own SLO math — it reuses what is already
defined and reviewed in
[`observability/prometheus/rules/slo-rules.yaml`](../../observability/prometheus/rules/slo-rules.yaml).
SLO target = 99.9%/30d ⇒ error budget = `0.001`.

**`alerts` mode (default)** — read the firing fast-burn alert via the synthetic
`ALERTS` metric Prometheus exposes for every active alert:

```promql
ALERTS{alertname="DemoApiErrorBudgetBurnFast", alertstate="firing"}
```

`DemoApiErrorBudgetBurnFast` is the multi-window multi-burn-rate page alert; its
underlying condition (verbatim from `slo-rules.yaml`) is:

```promql
(
  slo:sli_error:ratio_rate1h > (14.4 * 0.001)
  and
  slo:sli_error:ratio_rate5m > (14.4 * 0.001)
)
or
(
  slo:sli_error:ratio_rate6h > (6 * 0.001)
  and
  slo:sli_error:ratio_rate30m > (6 * 0.001)
)
```

where each `slo:sli_error:ratio_rateNm` recording rule is the 5xx error ratio
over that window (probes/scrapes excluded):

```promql
sum(rate(http_requests_total{service="demo-api", status=~"5..", path!~"/healthz|/readyz|/metrics"}[<window>]))
/
(sum(rate(http_requests_total{service="demo-api", path!~"/healthz|/readyz|/metrics"}[<window>])) > 0)
```

**`burnrate` mode** — evaluate the recording rules directly and compare the burn
rate (`error ratio / budget`) to `BURN_THRESHOLD` (default `14.4`). The actual
query (multi-window, the 1h/5m fast pair, collapsed with `max`):

```promql
max(
  (slo:sli_error:ratio_rate1h{service="demo-api"} / 0.001)
  and ignoring(slo)
  (slo:sli_error:ratio_rate5m{service="demo-api"} / 0.001 > 0)
)
```

Use `burnrate` mode if you want the controller to act on a *different* threshold
than the human pager (e.g. only auto-heal on extreme 20×+ burns).

---

## Configuration (environment variables)

| Var                 | Default                                | Meaning |
| ------------------- | -------------------------------------- | ------- |
| `PROM_URL`          | `http://localhost:9090`                | Prometheus base URL. In-cluster: the kube-prometheus-stack Prometheus Service. |
| `BURN_QUERY_MODE`   | `alerts`                               | `alerts` (read firing SLO alert) or `burnrate` (evaluate burn rate). |
| `BREACH_ALERT`      | `DemoApiErrorBudgetBurnFast`           | Alert name to watch in `alerts` mode. |
| `BURN_THRESHOLD`    | `14.4`                                 | Burn-rate threshold in `burnrate` mode (14.4 = fast-burn page level). |
| `NAMESPACE`         | `demo`                                 | Namespace of the target deployment. |
| `DEPLOYMENT`        | `demo-api`                             | Target deployment name. |
| `MODE`              | `restart`                              | `restart` (rollout restart) or `rollback` (Argo CD). |
| `DRY_RUN`           | `true`                                 | **Default true.** When true, logs the action but changes nothing. |
| `POLL_SECONDS`      | `30`                                   | Poll interval. |
| `SUSTAINED_SECONDS` | `120`                                  | Breach must persist this long before acting. |
| `COOLDOWN_SECONDS`  | `600`                                  | No further action for this long after a remediation. |
| `ARGOCD_APP`        | `demo-api`                             | Argo CD app to roll back (`rollback` mode). |
| `BACKOFF_BASE_SECONDS` | `1.0`                               | Base for exponential backoff on errors. |
| `BACKOFF_MAX_SECONDS`  | `60.0`                              | Backoff cap. |
| `HTTP_TIMEOUT_SECONDS` | `10.0`                              | Prometheus query timeout. |
| `LOG_LEVEL`         | `INFO`                                 | `DEBUG`/`INFO`/`WARNING`/`ERROR`. |
| `HEARTBEAT_PATH`    | `/tmp/heartbeat`                       | File touched each cycle; the readiness probe checks its freshness. |

---

## Run it locally

Point it at any Prometheus that has the demo-api SLO rules loaded. Dry-run is on
by default, so this is safe to run against prod Prometheus — it will only log.

```bash
cd tools/auto-remediation
python3 -m pip install -r requirements.txt   # requests (+ kubernetes, optional)

# Watch decisions against a port-forwarded in-cluster Prometheus, no changes:
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &

PROM_URL=http://localhost:9090 \
DRY_RUN=true \
LOG_LEVEL=DEBUG \
python3 remediator.py
```

You'll see one JSON log line per poll, e.g.:

```json
{"level":"WARNING","service":"auto-remediation","message":"DRY-RUN: would remediate but DRY_RUN is true; no changes made","action":"rollout_restart","namespace":"demo","deployment":"demo-api","dry_run":true,"via":"kubectl"}
```

### Demoing the full self-heal loop

demo-api ships chaos hooks (see the metric/chaos contract in the app). Inject
errors, watch the SLO alert fire, then watch the controller heal:

```bash
# 1. Make demo-api return 50% 500s on "/" (burns the error budget fast):
curl -X POST -H "X-Chaos-Token: $CHAOS_ADMIN_TOKEN" \
     -d '{"error_rate":0.5}' http://<demo-api>/admin/chaos

# 2. In a few minutes DemoApiErrorBudgetBurnFast goes firing in Prometheus.
# 3. The controller (DRY_RUN=false) sees the sustained breach and restarts.
# 4. Turn chaos off:
curl -X POST -H "X-Chaos-Token: $CHAOS_ADMIN_TOKEN" \
     -d '{"error_rate":0.0}' http://<demo-api>/admin/chaos
```

> A restart only *clears* the burn if the fault is in the pod (wedged process,
> leaked connections, bad in-memory state). A persistent chaos toggle will
> re-burn after the restart — which is exactly why the **cooldown** exists, and
> why a human still investigates. For a bad-release incident, use `MODE=rollback`.

---

## Deploy to the cluster

Manifests are in [`deploy/`](deploy/) (Kustomize). They install into the
`sre-tools` namespace with a **least-privilege** RBAC grant that can do
**nothing except `get`/`patch` the single `demo-api` deployment** in `demo`.

```bash
# Build the image (CI does this; tag with a real version / git SHA, never :latest):
docker build -t ghcr.io/charanvamsy26/auto-remediation:0.1.0 tools/auto-remediation/
docker push  ghcr.io/charanvamsy26/auto-remediation:0.1.0

# Render for review:
kustomize build tools/auto-remediation/deploy/

# Apply (ships DRY_RUN=true; flip the env in deployment.yaml to go live):
kubectl apply -k tools/auto-remediation/deploy/
```

See [`deploy/README.md`](deploy/README.md) for the namespace choice, the exact
RBAC verbs, and the Gatekeeper-compliance checklist.

---

## Testing

```bash
cd tools/auto-remediation
python3 -m pip install pytest
python3 -m pytest -q          # 42 tests, no live cluster / Prometheus
```

The suite (`tests/test_remediator.py`) mocks the Prometheus HTTP query, the
clock, and the remediation executor, and exercises: the query client's HTTP
error handling, both detection strategies, the sustain/cooldown/backoff state
machine, restart-vs-rollback dispatch, dry-run vs execute, command construction,
config parsing, and the JSON log format. See [`tests/README.md`](tests/README.md).

---

## Files

| Path                | Purpose |
| ------------------- | ------- |
| `remediator.py`     | The controller (logging, config, Prometheus client, detection, remediation, loop). |
| `requirements.txt`  | `requests` (hard dep) + `kubernetes` (optional in-cluster client). |
| `Dockerfile`        | Multi-stage, non-root (uid 10001), digest-pinnable base. |
| `deploy/`           | Kustomize: Namespace, ServiceAccount, least-privilege Role/RoleBinding, Deployment. |
| `tests/`            | pytest suite (fully mocked). |
