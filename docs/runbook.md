# SRE incident runbook

On-call reference for `my-project`. Each section maps an alert (from `observability/prometheus/rules/`) to **diagnosis** → **remediation**. Alerts carry a `runbook_url` annotation pointing here; alert names below match those rules exactly.

## How to triage, fast

1. **Acknowledge** the page in your alerting tool.
2. **Open the dashboard** linked in the alert (`demo-api-overview` for the workload, `kubernetes-cluster` for infra) — see "Reading the dashboards" below.
3. **Check the SLO panel first** — is the error budget actually burning, or is this a coarse backstop alert? SLO burn alerts (`DemoApiAvailabilitySLO`) are the primary reliability signal; `DemoApiHighErrorRate` is a backstop.
4. **Establish blast radius:** one pod, the whole service, or the cluster?
5. If a deploy is implicated, **roll back via ArgoCD** (below) before deep debugging — restore service, then investigate.

## Reading the dashboards

**demo-api-overview** (`observability/grafana/dashboards/demo-api-overview.json`)
- **RED panels** — request **R**ate, **E**rror ratio, and latency (p50/p95/p99). These are driven by the recording rules in `recording-rules.yaml`, which exclude probe/scrape paths so the math reflects only user traffic.
- **SLO compliance + 30d error-budget gauge** — how much budget remains in the rolling window.
- **Burn-rate panels** — short/long-window burn rates that drive the page/ticket alerts.

**kubernetes-cluster** (`observability/grafana/dashboards/kubernetes-cluster.json`)
- Node readiness, CPU/memory saturation, container restarts, and scrape-target up-ness.

Both load via the Grafana dashboard sidecar — no manual import.

---

## Workload alerts (`demo-api`)

### `DemoApiAvailabilitySLO` (page on fast burn / ticket on slow burn)
**Meaning:** the 99.9%/30d error budget is burning faster than allowed. Page-level = 14.4x@1h or 6x@6h; ticket-level = 3x@24h or 1x@72h.

**Diagnose**
```bash
kubectl -n demo get pods
kubectl -n demo logs deploy/demo-api --tail=100        # JSON logs; look for status>=500
```
- Open `demo-api-overview` → which status codes dominate the error ratio? Did errors start at a deploy boundary?
- Check whether `/readyz` is flapping (DB dependency).

**Remediate**
- If a recent deploy caused it → **roll back via ArgoCD** (below).
- If the database is the cause → see `DemoApiHighErrorRate` / readiness guidance below.
- If load-driven → confirm the HPA is scaling (`HPAMaxedOut`?).
- Once stable, record budget spend; if budget is exhausted, the error-budget policy in `docs/slo.md` freezes feature rollouts until recovery.

### `DemoApiHighErrorRate` (warning)
**Meaning:** 5xx ratio > 5% for 10m. Coarse backstop to the SLO alert.

**Diagnose**
```bash
kubectl -n demo logs deploy/demo-api --tail=200 | grep '"status":5'
kubectl -n demo get endpoints demo-api                 # are pods actually backing the Service?
```
- Is Aurora reachable? `demo-api` returns errors/`503` on DB failure by design.

**Remediate**
- DB issue → verify the RDS cluster status in the AWS console / `kubernetes-cluster` infra view; check the Secrets Manager–sourced `DATABASE_URL`. Recover the DB or fail readiness so traffic drains cleanly.
- Bad code → roll back via ArgoCD.

### `DemoApiHighLatencyP99` (warning)
**Meaning:** p99 latency > 500ms for 10m.

**Diagnose**
- `demo-api-overview` latency panel: p50 vs p99 — broad slowdown (saturation) or tail only (a slow dependency / GC)?
- Check CPU/memory saturation and whether the HPA is keeping up.

**Remediate**
- Saturation → ensure HPA is scaling; if `HPAMaxedOut`, raise `maxReplicas`.
- Slow DB → investigate Aurora query latency / connections.

### `DemoApiNoTraffic` (warning)
**Meaning:** zero user requests for 15m — for a demo endpoint, almost always a broken route, not real idleness.

**Diagnose**
```bash
kubectl -n demo get ingress demo-api
kubectl -n demo describe ingress demo-api              # ALB events / target group health
kubectl -n demo get servicemonitor                     # is Prometheus discovering it?
```

**Remediate**
- Fix the Ingress/Service path; confirm the AWS LB Controller (wave 1) is Healthy and the ALB target group has healthy targets.

### `HPAMaxedOut` (warning)
**Meaning:** the HPA has been pinned at `maxReplicas` for 15m — out of headroom.

**Diagnose**
```bash
kubectl -n demo get hpa
kubectl -n demo describe hpa demo-api
```

**Remediate**
- Raise `maxReplicas` (chart values) if load is legitimate, or find the load source. Confirm nodes can schedule more pods (`kubernetes-cluster` node saturation).

---

## Kubernetes / cluster alerts

### `PodCrashLooping` (critical)
```bash
kubectl -n <ns> get pods
kubectl -n <ns> logs <pod> --previous                  # the crash, not the restart
kubectl -n <ns> describe pod <pod>                     # OOMKilled? failing probe? config?
```
**Remediate:** fix config/secret/resource limits in Git → ArgoCD syncs; or roll back the change that introduced the crash.

### `PodNotReady` / `DeploymentReplicasMismatch` (warning)
```bash
kubectl -n <ns> describe pod <pod>                      # scheduling, image pull, probe failures
kubectl -n <ns> get events --sort-by=.lastTimestamp
```
**Remediate:** address the root cause (capacity, image, readiness). For `demo-api`, a not-ready pod with a failing `/readyz` usually means the DB probe is failing — see `DemoApiHighErrorRate`.

### `KubeNodeNotReady` (critical)
```bash
kubectl get nodes
kubectl describe node <node>                            # kubelet, disk, network conditions
```
**Remediate:** let the node group / Karpenter replace the node; cordon & drain if it's flapping. Confirm pods rescheduled.

### `KubeNodeMemoryPressure` / `NodeFilesystemAlmostFull` (warning)
**Remediate:** identify the heavy pod, right-size requests/limits, and scale out node capacity. For disk, clear/rotate logs or grow the volume.

---

## Monitoring meta alerts

### `TargetDown` (critical)
**Meaning:** >10% of a job's scrape targets are unreachable for 10m — metrics for that job are unreliable. This alert **inhibits** the latency/error/SLO alerts that depend on the same target (configured in Alertmanager), so trust the cause, not the symptom.

**Diagnose**
```bash
# Prometheus UI -> Status -> Targets : which job is down and why (DNS, NetworkPolicy, pod down)?
kubectl -n demo get servicemonitor,endpoints
```
**Remediate:** restore the target (the pod/Service), or fix the NetworkPolicy / ServiceMonitor selector.

### `PrometheusRuleEvaluationFailing` (warning)
**Remediate:** a recording/alerting rule is malformed — check the most recently changed PromQL in `observability/prometheus/rules/`; fix and let ArgoCD sync.

### `PrometheusTSDBWriteFailures` (critical)
**Meaning:** WAL corruption — data integrity at risk.
**Remediate:** check the underlying gp3 PVC / disk health; recover or replace the Prometheus volume.

### `Watchdog` (always firing — dead-man's switch)
This alert is *supposed* to fire continuously. If it **stops**, your alerting pipeline (Prometheus → Alertmanager → Slack) is broken — treat **silence** as the incident.

---

## Rollback via ArgoCD

GitOps gives you two complementary rollback paths. Prefer the Git path for an auditable, permanent fix; use the ArgoCD history path to restore service immediately during an incident.

**Fast restore (ArgoCD history):**
```bash
argocd app history demo-api                     # list previous synced revisions
argocd app rollback demo-api <REVISION>         # roll back to a known-good revision
argocd app get demo-api                         # confirm Healthy / Synced
```
> Note: `selfHeal` will try to reconcile back to `main`. For a sustained rollback, also revert in Git (below) — otherwise ArgoCD re-applies the bad revision.

**Permanent rollback (Git revert — the correct end state):**
```bash
git revert <bad-commit> && git push            # e.g. revert the image-tag bump in values.yaml
# ArgoCD auto-syncs main back to the good state
```

**Pause auto-sync while you investigate (optional):**
```bash
argocd app set demo-api --sync-policy none      # stop selfHeal/auto-prune temporarily
# ... investigate / manual fix ...
argocd app set demo-api --sync-policy automated # restore GitOps
```

## Auto-remediation controller (self-healing)

A self-healing controller (`tools/auto-remediation/`, deployed in the `sre-tools`
namespace) acts as the **first responder** for the most common demo-api failure
mode — a wedged process throwing 5xx that a restart clears. It does **not**
replace the page: Alertmanager routing is unchanged, so you are still paged. The
controller just removes the human round-trip from the critical path, which is the
~40% MTTR reduction. End-to-end walkthrough: [`reliability-demo.md`](reliability-demo.md).

**What it watches.** Every `POLL_SECONDS` (default 30s) it polls Prometheus for a
sustained SLO breach, using one of two strategies (`BURN_QUERY_MODE`):
- `alerts` (default): the canonical fast-burn page alert is firing —
  `ALERTS{alertname="DemoApiErrorBudgetBurnFast", alertstate="firing"}`. This is
  the *same signal that pages you*, so the bot and the human act on one trigger.
- `burnrate`: it evaluates the `slo:sli_error:ratio_rate1h/5m` recording rules
  divided by the 0.001 budget and compares to `BURN_THRESHOLD` (default 14.4) —
  use this to auto-heal only on a *higher* bar than the pager (e.g. 20×+).

**What it does.** Once the breach has persisted for `SUSTAINED_SECONDS`
(default 120s — blips are ignored) and it is not within `COOLDOWN_SECONDS`
(default 600s — anti-flap, no restart storms), it remediates per `MODE`:
- `restart` (default): a rolling restart of `deployment/demo-api` in `demo` —
  identical to `kubectl rollout restart deployment/demo-api -n demo` (patches the
  pod-template `kubectl.kubernetes.io/restartedAt` annotation). Uses the
  in-cluster Kubernetes client when available, else shells out to `kubectl`.
- `rollback`: `argocd app rollback <ARGOCD_APP>` — for a *bad release* (a restart
  won't fix code; use this or the [ArgoCD rollback](#rollback-via-argocd) path).

It emits one structured single-line JSON log per decision. To read what it did:

```bash
kubectl -n sre-tools logs deploy/auto-remediation --tail=100   # JSON: action, namespace, deployment, dry_run, via
```

> A restart only *clears* a pod-local fault. If the cause is persistent (DB down,
> a still-active chaos toggle, a bad image), the burn re-fires after the cooldown
> and a human must take over — that is by design.

### How to disable it / set DRY_RUN

- **Dry-run (observe only, no changes):** the controller **ships with `DRY_RUN=true`**.
  In dry-run it logs `"DRY-RUN: would remediate but DRY_RUN is true; no changes made"`
  and touches nothing. To force it back to observe-only on a live deployment:
  ```bash
  kubectl -n sre-tools set env deploy/auto-remediation DRY_RUN=true
  ```
  (For a permanent setting, change `DRY_RUN` in
  `tools/auto-remediation/deploy/deployment.yaml` and let ArgoCD/kustomize sync.)
- **Fully disable (stop it acting at all):** scale it to zero —
  ```bash
  kubectl -n sre-tools scale deploy/auto-remediation --replicas=0
  ```
  Re-enable with `--replicas=1`. Its RBAC is least-privilege (only `get`/`patch`
  on the single `demo-api` deployment), so a stopped controller removes the only
  automated actor on the workload.

### Manual fallback

If the controller is disabled, lagging, or hit its cooldown and the burn
persists, perform its action by hand — it is exactly the on-call first step:

```bash
kubectl -n demo rollout restart deployment/demo-api     # the restart the bot would do
kubectl -n demo rollout status  deployment/demo-api     # watch it recover
```

If a restart does not clear it (bad release), fall back to the
[ArgoCD rollback](#rollback-via-argocd) above. Always confirm recovery on the
`demo-api-slo-burn` / `demo-api-overview` dashboards before standing down.

---

## Escalation & post-incident

- Ownership routing is by the `team` label on each alert (currently `platform`); Alertmanager routes severity-based, with SLO burn alerts threaded into the dedicated SLO Slack channel.
- After resolution: record error-budget spend, capture the timeline, and file follow-ups. If the budget is exhausted, apply the freeze described in `docs/slo.md`.
