# App-level chaos driver (mechanism B — no mesh required)

Drive demo-api's **guarded chaos endpoint** (`/admin/chaos`) to inject faults
that flow through the app's own instrumentation. This is **mechanism B** of two
(mechanism A is Chaos Mesh in [`../chaos-mesh/`](../chaos-mesh/)). It needs no
cluster privileges and no Chaos Mesh — just network reach to the service — so it
works on a laptop / kind / minikube.

Because the injected 5xx / latency / outage go through the app's normal
`after_request` path, they **burn the SLO error budget** and light up the
demo-api-overview dashboard and the `DemoApi*` alerts — which is exactly what you
want for an SLO/error-budget demo. (Chaos Mesh `HTTPChaos`, by contrast, forges
500s outside the app, so those don't register in the app's RED metrics.)

> **Never run this against production.** `chaos.py` refuses URLs that look like
> prod unless you pass `--i-know-what-im-doing`. See [`../README.md`](../README.md).

## Files

| File                         | Purpose                                                        |
| ---------------------------- | ------------------------------------------------------------- |
| [`chaos.py`](./chaos.py)     | The driver. stdlib-only Python 3.8+ CLI. The source of truth. |
| [`induce.sh`](./induce.sh)   | Convenience wrapper: turn chaos **on** (env-configurable).    |
| [`recover.sh`](./recover.sh) | Convenience wrapper: turn **all** chaos **off** (idempotent). |

## The chaos contract (matches `app/src/app.py`)

```
GET/POST  {BASE_URL}/admin/chaos
auth:     X-Chaos-Token: <token>        (or  Authorization: Bearer <token>)
body:     {"error_rate": 0.0-1.0, "latency_ms": >=0, "outage": bool}
            error_rate  -> fraction of "/" requests that return 500
            latency_ms  -> extra milliseconds of latency on "/"
            outage      -> true makes /readyz return 503 (pod NotReady;
                           liveness stays green, so the pod is NOT restarted)
```

The endpoint is **disabled (404)** unless the demo-api pod was deployed with
`CHAOS_ADMIN_TOKEN` set; a wrong/missing token returns **401**.

## Prerequisites

1. **demo-api reachable.** Locally, port-forward it:
   ```bash
   kubectl -n demo port-forward svc/demo-api 8000:80
   export BASE_URL=http://localhost:8000
   ```
   (Or run the app directly: `cd app && CHAOS_ADMIN_TOKEN=dev-secret \
   gunicorn -b 0.0.0.0:8000 'src.app:app'`.)

2. **The shared token.** Export the same token the pod was deployed with — it is
   intentionally **not** stored in this repo:
   ```bash
   export CHAOS_ADMIN_TOKEN='<the-demo-api-chaos-token>'
   ```

## Usage

```bash
# Inspect current state (no change).
./chaos.py status

# Induce individual faults:
./chaos.py errors  --rate 0.5      # 50% of "/" requests return 500
./chaos.py latency --ms 800        # +800ms latency on "/"
./chaos.py outage                  # /readyz -> 503 (pod drained from rotation)
./chaos.py set --rate 0.2 --ms 300 # several knobs at once

# Recover everything (idempotent):
./chaos.py off

# Or use the env-driven wrappers:
ERROR_RATE=0.3 LATENCY_MS=400 ./induce.sh
./recover.sh
```

Exit codes: `0` ok, `1` usage/precondition (e.g. missing token, prod guard),
`2` HTTP/transport (e.g. 401/404, service unreachable).

## Safety & idempotency

- **Idempotent.** `off` and `set` just POST the desired state; re-running
  converges. Run `recover.sh` any time you're unsure of the current state.
- **Prod guard.** A `BASE_URL` containing `prod`/`production` is rejected unless
  `--i-know-what-im-doing` is passed. Treat that flag as a loaded gun.
- **No secrets in the repo.** The token is read from `CHAOS_ADMIN_TOKEN` at run
  time only.

## A 3-minute SLO demo

```bash
export BASE_URL=http://localhost:8000
export CHAOS_ADMIN_TOKEN='<token>'

# 1) Drive some baseline traffic against "/" (separate terminal):
#    while true; do curl -s "$BASE_URL/" >/dev/null; done

# 2) Burn the budget: 30% of "/" requests start 500ing.
./chaos.py errors --rate 0.3
#    -> watch the 5xx ratio + p99 on the demo-api-overview dashboard;
#       DemoApiHighErrorRate then DemoApiErrorBudgetBurnFast should fire.

# 3) Recover and watch the alerts resolve.
./chaos.py off
```
