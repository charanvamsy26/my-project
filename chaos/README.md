# Chaos engineering — the demo-api reliability demo

This directory is the **reliability demo** for the platform: deliberately break
demo-api in controlled, reversible ways and watch the observability stack
(Prometheus rules, the demo-api-overview dashboard, the 99.9% / 30d SLO and its
error-budget alerts) react. It proves the platform doesn't just *run* the service
— it *notices* when the service is unhealthy.

There are **two complementary mechanisms**, deliberately:

| Mechanism | Where | Needs | Burns the app's RED metrics / SLO? | Demonstrates |
| --------- | ----- | ----- | ---------------------------------- | ------------ |
| **A. Cluster-native** ([`chaos-mesh/`](./chaos-mesh/)) | Chaos Mesh CRDs in `chaos-testing`, targeting `demo` | A real/kind cluster + privileged DaemonSet | Pod-kill & latency: yes. HTTPChaos 500s: **no** (forged outside the app) | the *tooling* — pod kills, network shaping, HTTP faults at the infra layer |
| **B. App-level** ([`scripts/`](./scripts/)) | `chaos.py` → demo-api `/admin/chaos` | Just network reach to the service | **Yes** — faults flow through the app's own instrumentation | the *SLO/error-budget* story end to end, even on a laptop |

Use **B** for the SLO/alerting demo (it actually burns the budget). Use **A** to
show off real cluster-native chaos tooling. They share the same target: pods
labelled `app.kubernetes.io/name=demo-api` in namespace `demo`.

---

## ⚠️ Safety note — NEVER run chaos against production

Chaos is a controlled experiment, not a stunt. The rules here are non-negotiable:

- **Target dev/staging only — never prod.** Every manifest is pinned to namespace
  `demo` (the dev environment); the app-level `chaos.py` actively **refuses** any
  URL containing `prod`/`production` unless you pass `--i-know-what-im-doing`.
- **Short, self-terminating blasts.** Chaos Mesh experiments carry 30–60s
  durations and revert when deleted; the app-level driver is one POST you can
  reverse instantly with `recover.sh`.
- **Always have the off switch ready.** For mechanism B that is
  `scripts/recover.sh` (idempotent). For mechanism A it is
  `kubectl -n demo delete -f <experiment>.yaml`.
- **Announce it.** Tell whoever watches the alerts before you start, so a real
  incident isn't mistaken for the demo (and vice-versa).
- **The token is a secret.** `CHAOS_ADMIN_TOKEN` is never stored in this repo;
  export it at run time. If it's unset on the pod, `/admin/chaos` is disabled
  (404) — that's the safe default.

> If you are not 100% sure the target is non-prod, **stop**. The error budget you
> save may be your own.

---

## The narrative (what to show, in order)

Assumes the platform is up: demo-api deployed in `demo`, kube-prometheus-stack in
`monitoring` scraping it via the chart's ServiceMonitor, Grafana showing
**demo-api-overview**, and the SLO/alert rules loaded.

### 0. Baseline — everything green
Open **demo-api-overview**. Request rate is steady, 5xx ratio ~0, p99 well under
the 500ms SLO threshold, error budget full. Drive a little traffic against `/`:

```bash
export BASE_URL=http://localhost:8000     # e.g. kubectl -n demo port-forward svc/demo-api 8000:80
while true; do curl -s "$BASE_URL/" >/dev/null; sleep 0.2; done   # in a side terminal
```

### 1. Availability burn (mechanism B) — burn the error budget
```bash
export CHAOS_ADMIN_TOKEN='<the-demo-api-chaos-token>'
cd scripts
./chaos.py errors --rate 0.3        # 30% of "/" requests now 500
```
Watch the 5xx ratio jump on the dashboard. `DemoApiHighErrorRate` fires, then —
as the budget burns fast — `DemoApiErrorBudgetBurnFast`. Recover and watch them
resolve:
```bash
./chaos.py off
```

### 2. Latency pressure — push the p99 SLO
```bash
./chaos.py latency --ms 800         # +800ms on "/" (SLO p99 budget is 500ms)
```
p99 on `http_request_duration_seconds` climbs above 0.5s;
`DemoApiHighLatencyP99` fires. Then `./chaos.py off`.

(Cluster-native equivalent: `kubectl -n demo apply -f chaos-mesh/network-latency.yaml`.)

### 3. Readiness outage — graceful degradation, no crash-loop
```bash
./chaos.py outage                   # /readyz -> 503; liveness stays green
```
The pod goes **NotReady** (drained from the Service/ALB) but is **not** restarted
(`/healthz` still passes). `PodNotReady` fires; the app degrades gracefully
instead of crash-looping. Recover:
```bash
./chaos.py off
```

### 4. Cluster-native resilience (mechanism A) — self-healing
```bash
# Requires Chaos Mesh installed (see chaos-mesh/install.md).
kubectl -n demo apply -f chaos-mesh/pod-kill.yaml
kubectl -n demo get pods -w         # one pod dies, Kubernetes reschedules it
```
With the prod overlay (≥2 replicas + PDB) the kill is zero-impact; in single-
replica dev you see the brief blip and the self-heal.

### 5. All clear
```bash
cd scripts && ./recover.sh          # idempotent: clears every app-level knob
kubectl -n demo delete -f chaos-mesh/ --ignore-not-found   # remove any experiments
```
Dashboard returns to green; alerts resolve; the error budget stops burning.

---

## Layout

```
chaos/
├── README.md                 # this file — narrative + safety note
├── chaos-mesh/               # mechanism A: cluster-native (Chaos Mesh)
│   ├── README.md
│   ├── install.md            # pinned install into the chaos-testing namespace
│   ├── pod-kill.yaml         # PodChaos    — kill one demo-api pod
│   ├── network-latency.yaml  # NetworkChaos — +200ms latency
│   └── http-fault.yaml       # HTTPChaos    — 500s on "/"
└── scripts/                  # mechanism B: app-level (no mesh needed)
    ├── README.md
    ├── chaos.py              # stdlib driver for /admin/chaos
    ├── induce.sh             # wrapper: turn chaos on
    └── recover.sh            # wrapper: turn all chaos off (idempotent)
```

## How this stays consistent with the rest of the platform

- **Selectors/labels/namespace match reality.** All Chaos Mesh experiments select
  `app.kubernetes.io/name=demo-api` in `demo` — the demo-api Helm chart's stable
  selector label — and target container port `8000` / route template `/`.
- **The chaos contract is verbatim.** `chaos.py` speaks exactly the
  `/admin/chaos` contract implemented and tested in `app/src/app.py`
  (`X-Chaos-Token`/`Bearer`, `{error_rate, latency_ms, outage}`, 404-when-disabled,
  401-on-bad-token).
- **Gatekeeper-clean.** This layer adds **no** long-running workloads to `demo`,
  so it introduces nothing for the project's Gatekeeper constraints (resources,
  hardened security context, probes, ghcr/ECR images, no `:latest`, ownership
  labels) to reject. Chaos Mesh's own privileged pods live in the separate
  `chaos-testing` namespace by design (see `chaos-mesh/install.md`).
- **Metrics contract.** Mechanism B's faults register as
  `http_requests_total{service="demo-api",path="/",status="500"}` and inflate
  `http_request_duration_seconds`, so they drive the same recording/SLO/alert
  rules the rest of the stack already consumes.
