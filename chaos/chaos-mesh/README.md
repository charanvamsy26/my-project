# Chaos Mesh experiments (mechanism A — cluster-native)

Cluster-native fault injection for the demo-api reliability demo, driven by
[Chaos Mesh](https://chaos-mesh.org/). This is **mechanism A** of two; mechanism
B is the app-level driver in [`../scripts/`](../scripts/). See the top-level
[`../README.md`](../README.md) for the full narrative and the safety note.

> **Never run any of this against production.** Everything here is scoped to
> namespace `demo` and short, self-terminating durations, but the operator
> running it is the last line of defense. See the safety section in
> [`../README.md`](../README.md).

## What's here

| File                                       | Kind          | Fault                                                   |
| ------------------------------------------ | ------------- | ------------------------------------------------------- |
| [`install.md`](./install.md)               | runbook       | Pinned install of Chaos Mesh `2.6.3` into `chaos-testing` |
| [`pod-kill.yaml`](./pod-kill.yaml)         | `PodChaos`    | Kill one demo-api pod (self-healing / rescheduling)     |
| [`network-latency.yaml`](./network-latency.yaml) | `NetworkChaos`| +200ms (±50ms) egress latency (p99 SLO pressure)        |
| [`http-fault.yaml`](./http-fault.yaml)     | `HTTPChaos`   | Return 500 for GET `/` (availability error-budget burn) |

All three target the **same selector** as the Helm chart:

```yaml
namespaces: [demo]
labelSelectors:
  app.kubernetes.io/name: demo-api
```

and use **short durations** (30–60s) so they auto-recover. Deleting an
experiment object reverts its fault immediately.

## Install Chaos Mesh first

Follow [`install.md`](./install.md). TL;DR (dev cluster, containerd runtime):

```bash
kubectl create namespace chaos-testing --dry-run=client -o yaml | kubectl apply -f -
helm repo add chaos-mesh https://charts.chaos-mesh.org && helm repo update
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-testing --version 2.6.3 \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock --wait
```

Chaos Mesh runs in its own **privileged** `chaos-testing` namespace (its daemon
mounts the host CRI socket). It does **not** run in `demo`, which enforces the
restricted Pod Security profile and the project Gatekeeper constraints — the
experiments merely *target* `demo` pods via label selector. See `install.md` for
why this separation is correct.

## Run an experiment

```bash
# Start a fault (each is short and self-terminating).
kubectl -n demo apply -f pod-kill.yaml

# Observe the effect.
kubectl -n demo get pods -w
kubectl -n demo describe podchaos demo-api-pod-kill

# Stop early / clean up (deleting the object reverts the fault).
kubectl -n demo delete -f pod-kill.yaml
```

Swap in `network-latency.yaml` or `http-fault.yaml` the same way.

## What to watch (ties into the observability stack)

| Experiment       | Expect to see                                                                 |
| ---------------- | ----------------------------------------------------------------------------- |
| `pod-kill`       | Pod restarts in `kubectl get pods`; `PodNotReady` / `DeploymentReplicasMismatch` flicker then clear |
| `network-latency`| p99 of `http_request_duration_seconds` climbs on **demo-api-overview**; `DemoApiHighLatencyP99` may fire |
| `http-fault`     | 5xx ratio spikes; `DemoApiHighErrorRate` → `DemoApiErrorBudgetBurnFast` (see note below) |

> **Metrics caveat for `http-fault`:** Chaos Mesh forges the 500 in the proxy
> layer *outside* the Flask app, so it is **not** counted by the app's own
> `http_requests_total` series or the SLO recording rules. It still shows up in
> ALB/ingress/client-side error metrics. To make the burn register in the app's
> RED metrics and the 99.9% SLO, use **mechanism B** (`../scripts/`), whose 500s
> flow through the app's instrumentation. Both mechanisms are intentional and
> complementary — A demonstrates the tooling; B drives the dashboards/alerts.
