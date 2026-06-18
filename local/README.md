# Local demo — run the whole SRE story on your laptop (no AWS)

This directory turns the cloud platform into a **one-command, zero-AWS demo** that
runs on a local [kind](https://kind.sigs.k8s.io/) cluster. You get the *same*
`demo-api`, the *same* kube-prometheus-stack + Grafana dashboards, the *same*
OPA Gatekeeper guardrails, and the *same* SLO **error-budget-burn → page →
auto-remediation** loop — just pointed at a local cluster instead of EKS.

> **What you get:** a Kubernetes 1.30 [kind](https://kind.sigs.k8s.io/) cluster
> named **`eks-gitops-platform-local`** running `demo-api`, Prometheus, Grafana, and
> Gatekeeper, with the burn demo and live screenshot capture wired into `make`.

Everything here is **local-only**: ALB/RDS/IRSA and other cloud-only bits are
disabled by the local Helm overlay, and the one credential
(`Grafana admin/admin`) is a throwaway local password — never a real secret.

![demo-api SLO burn dashboard (illustrative mock)](../docs/img/slo-burn-dashboard.svg)

> The image above is an **illustrative diagram**, not a screenshot. Run
> `make demo-up && make demo-screenshots` to capture the **real** dashboards
> into `local/screenshots/`.

---

## Prerequisites

You need four CLIs: **docker**, **kind**, **kubectl**, **helm**. They are *not*
assumed to be pre-installed. The `make demo-*` targets check for each with
`command -v` and exit with an install hint if one is missing, so you'll get a
clear error rather than a confusing failure.

| Tool | Why | Install hint (macOS / Linux) |
| --- | --- | --- |
| **docker** | Builds the image and runs the kind node containers. | [Docker Desktop](https://docs.docker.com/get-docker/) (mac/win) · `brew install --cask docker` · Linux: distro Docker Engine or `colima start` |
| **kind** | Runs a Kubernetes 1.30 cluster inside Docker. | `brew install kind` · `go install sigs.k8s.io/kind@latest` · [releases](https://github.com/kubernetes-sigs/kind/releases) |
| **kubectl** | Talks to the cluster. | `brew install kubectl` · [install docs](https://kubernetes.io/docs/tasks/tools/) |
| **helm** | Installs the kube-prometheus-stack and the `demo-api` chart. | `brew install helm` · `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` |

Make sure Docker is **running** before you start (`docker info` should succeed),
and give it enough room: **~4 CPU and ~6 GB RAM** is comfortable
(kube-prometheus-stack is the heavy tenant). Less will still work, just slower.

### Zero-install option — GitHub Codespaces

Don't want to install anything? Open this repo in a **GitHub Codespace** (Code →
Codespaces → *Create codespace*). A Codespace ships with docker, kubectl, and
helm; install kind in the terminal and you're ready:

```bash
go install sigs.k8s.io/kind@latest   # or: brew install kind
make demo-up
```

> Codespaces use Docker-in-Docker, which kind supports. Port-forwards are
> auto-forwarded by the Codespaces UI — click the forwarded-port toast to open
> Grafana/Prometheus/the app in your browser.

---

## Quickstart — one command

From the **repository root**:

```bash
make demo-up
```

That single target is idempotent (safe to re-run) and does the whole bring-up:

1. **Preflight** — checks `docker`, `kind`, `kubectl`, `helm` are installed and
   Docker is running; fails fast with an install hint otherwise.
2. **Cluster** — creates the kind cluster **`eks-gitops-platform-local`** from
   [`local/kind/kind-config.yaml`](kind/) using node image
   **`kindest/node:v1.30.x`** (Kubernetes 1.30). Re-running reuses the existing
   cluster.
3. **Image** — builds `app/Dockerfile` as
   **`ghcr.io/charanvamsy26/demo-api:local`** and runs
   `kind load docker-image ghcr.io/charanvamsy26/demo-api:local --name eks-gitops-platform-local`
   so the node can pull it without a registry. The tag is **explicit (not
   `:latest`)** and under the **`ghcr.io/charanvamsy26/`** prefix, so it
   satisfies Gatekeeper's *allowed-registries* and *disallow-latest-tag*
   constraints.
4. **Namespaces** — creates `demo`, `monitoring`, and `gatekeeper-system`, and
   labels them so Gatekeeper exemptions and Prometheus namespace selection work.
5. **Gatekeeper** — installs OPA Gatekeeper into `gatekeeper-system`, then applies
   the repo's `policies/gatekeeper/templates` and `.../constraints`.
6. **Observability** — `helm upgrade --install` the
   `prometheus-community/kube-prometheus-stack` chart into `monitoring`, layering
   the repo base values with the local overlay
   [`local/helm-values/kube-prometheus-stack.local.yaml`](helm-values/) (sets
   `Grafana admin/admin`, drops the gp3 storageClass to the kind default,
   smaller resource requests).
7. **App** — `helm upgrade --install demo-api kubernetes/charts/demo-api` into
   `demo`, layering the local overlay
   [`local/helm-values/demo-api.local.yaml`](helm-values/) (image
   `:local` + `IfNotPresent`, **ingress disabled**, **no DATABASE_URL**, empty
   IRSA SA annotations, standard storageClass, laptop-sized requests — while
   keeping probes, limits, `runAsNonRoot` and dropped capabilities so Gatekeeper
   still admits it).
8. **Wait** — blocks on real readiness with
   `kubectl rollout status` / `kubectl wait` (never blind sleeps): Gatekeeper
   controller, kube-prometheus-stack, Grafana, and `demo-api` all Ready before
   the target returns.

When it finishes you'll see the access URLs (below). Total time on a warm Docker
is roughly **3–6 minutes** (most of it pulling the kube-prometheus-stack images).

---

## What gets installed

| Namespace | Component | Source | Notes |
| --- | --- | --- | --- |
| `demo` | **demo-api** (Flask) | `kubernetes/charts/demo-api` + `local/helm-values/demo-api.local.yaml` | Image `ghcr.io/charanvamsy26/demo-api:local`, ClusterIP only, DB-less. |
| `monitoring` | **kube-prometheus-stack** (Prometheus, Grafana, Alertmanager, exporters) | `observability/kube-prometheus-stack/values.yaml` + `local/helm-values/kube-prometheus-stack.local.yaml` | Scrapes demo-api's ServiceMonitor; loads dashboards + rules. |
| `monitoring` | **SLO rules + dashboards** | `observability/prometheus/rules/*`, `observability/grafana/dashboards/*.json` | Same recording/SLO/burn rules and the `demo-api-slo-burn` dashboard as prod. |
| `gatekeeper-system` | **OPA Gatekeeper** + constraints | `policies/gatekeeper/{templates,constraints}` | Admission guardrails: registry allow-list, no `:latest`, probes, limits, security context, labels. |

The cluster, namespaces, image tag, and registry prefix are the **shared
constants** the rest of the repo expects — so the local demo exercises the exact
same artifacts as the cloud path.

---

## Accessing Grafana, Prometheus, and the app

All access is via `kubectl port-forward` — there is **no cloud LoadBalancer/ALB**
locally. Open each in its own terminal (each command blocks):

```bash
# demo-api  ->  http://localhost:8000
kubectl -n demo port-forward svc/demo-api 8000:8000

# Grafana   ->  http://localhost:3000   (login: admin / admin)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

# Prometheus -> http://localhost:9090
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

> `make demo-up` prints these exact commands at the end; you can also run
> `make demo-urls` (if defined) to reprint them.

Then:

- **Grafana** — <http://localhost:3000>, log in with **`admin` / `admin`**
  (local-only password, set in `local/helm-values/kube-prometheus-stack.local.yaml`;
  Grafana will offer to change it — you can skip). Open the
  **`demo-api — Error Budget Burn`** dashboard (uid **`demo-api-slo-burn`**) at
  <http://localhost:3000/d/demo-api-slo-burn>.
- **Prometheus** — <http://localhost:9090> → *Status → Targets* should show the
  `demo-api` ServiceMonitor `UP`; *Status → Rules* shows the SLO/burn rules.
- **demo-api** — <http://localhost:8000/> (hello), `/healthz`, `/readyz`,
  `/metrics`.

> The Grafana Service/Prometheus Service names follow the kube-prometheus-stack
> release `kube-prometheus-stack`. If you installed under a different release
> name `<rel>`, substitute `svc/<rel>-grafana` and
> `svc/<rel>-kube-prometheus-stack-prometheus`. Confirm with
> `kubectl -n monitoring get svc`.

---

## Run the burn demo

This drives the full **steady → chaos burn → page → auto-remediation →
recovery** loop against the local cluster:

```bash
make demo
```

What it does (all against the local cluster, all reversible):

1. Establishes a healthy **baseline** of traffic to `demo-api` — error-budget
   remaining ~100%, burn rate flat.
2. Turns on **app-level chaos** via `demo-api`'s guarded `POST /admin/chaos`
   (the `chaos/scripts/` driver), so ~30% of `/` requests return `500`. Because
   the faults flow through the app's own instrumentation, they are counted in
   `http_requests_total` and **burn the real SLO error budget** — exactly what
   the dashboard and `DemoApiErrorBudgetBurnFast` page alert watch.
3. Lets the **fast burn rate** cross **14.4×** so the multi-window
   multi-burn-rate page alert fires, and the **error-budget-remaining** gauge
   visibly drains.
4. Runs the **auto-remediation controller** (`tools/auto-remediation/`) pointed
   at the local Prometheus; once the breach is *sustained*, it performs
   `kubectl rollout restart deployment/demo-api -n demo` — the safe
   first-responder action — collapsing MTTR.
5. **Recovers** — clears the chaos toggle, the 5xx ratio falls back to ~0,
   latency recovers, the burn rate drops below the threshold, and the alert
   resolves.

> The `CHAOS_ADMIN_TOKEN` that guards `/admin/chaos` is set locally by the
> `demo-api.local.yaml` overlay (a throwaway local value). If it were unset,
> `/admin/chaos` returns `404` (disabled) — the safe default.

Watch it happen live on the **`demo-api-slo-burn`** Grafana dashboard while
`make demo` runs. The narrative, PromQL queries, and expected log lines are
documented in detail in [`../docs/reliability-demo.md`](../docs/reliability-demo.md).

### Capture live screenshots

To grab **real** PNGs of the running dashboards (instead of the illustrative SVG):

```bash
make demo-screenshots
```

This renders the live Grafana panels (e.g. via the Grafana render API / a
headless browser) and writes them to **`local/screenshots/`**. Use these in a
PR, a portfolio writeup, or to compare against the illustrative
[`../docs/img/slo-burn-dashboard.svg`](../docs/img/slo-burn-dashboard.svg).

---

## Teardown

```bash
make demo-down
```

Deletes the entire kind cluster `eks-gitops-platform-local` (and everything in it). It's
idempotent — safe to run even if the cluster is already gone. Nothing is left
running on your machine and no cloud resources are ever created, so there is
nothing to bill.

---

## What this proves (SRE skills)

Running this locally exercises the same engineering as the cloud platform:

| SRE skill | Where it shows up in the local demo |
| --- | --- |
| **SLI/SLO/error-budget design** | A real 99.9% / 30-day availability SLO with auditable PromQL recording rules; the budget gauge drains live during the burn. |
| **Multi-window multi-burn-rate alerting** | The `DemoApiErrorBudgetBurnFast` page fires only on a sustained fast burn (14.4×@1h/5m or 6×@6h/30m), not on single-scrape blips. |
| **Observability** | A metric contract (`http_requests_total`, `http_request_duration_seconds`) wired through recording rules into a purpose-built Grafana burn dashboard. |
| **Chaos engineering** | Controlled, reversible app-level fault injection that burns the *real* budget, then is cleanly turned off. |
| **Auto-remediation / self-healing & MTTR** | A least-privilege controller acting on the *same signal that pages a human*, with sustain + cooldown safety, closing detect→act in seconds. |
| **Policy-as-code (admission)** | OPA Gatekeeper admits the workload only because it carries probes, limits, `runAsNonRoot`, dropped capabilities, ownership labels, an explicit non-`:latest` tag, and an allowed `ghcr.io/charanvamsy26/` registry. |
| **Kubernetes + Helm packaging** | The same hardened `demo-api` chart and kube-prometheus-stack, re-targeted to kind via a thin local overlay (cloud-only bits disabled, everything else identical). |

---

## Troubleshooting

**`ErrImagePull` / `ImagePullBackOff` — image not found.**
The local image lives only in your Docker daemon until it's loaded into kind.
`make demo-up` does this for you, but if you rebuilt the image manually, re-load it:

```bash
kind load docker-image ghcr.io/charanvamsy26/demo-api:local --name eks-gitops-platform-local
kubectl -n demo rollout restart deployment/demo-api
```

Confirm the node has it: `docker exec eks-gitops-platform-local-control-plane crictl images | grep demo-api`.

**Pods stuck `Pending` — not enough resources.**
Usually Docker doesn't have enough CPU/RAM. Raise Docker Desktop's limits
(Settings → Resources) to ~4 CPU / ~6 GB and re-run `make demo-up`. Check what's
wrong with:

```bash
kubectl -n monitoring describe pod -l app.kubernetes.io/name=prometheus | sed -n '/Events/,$p'
kubectl get nodes -o wide
```

The local overlays already shrink requests for a laptop; if it still won't fit,
lower Prometheus retention/resources in
`local/helm-values/kube-prometheus-stack.local.yaml`.

**Pods rejected at admission — Gatekeeper constraints blocking.**
If a deploy is denied, the message names the failing constraint. The local
overlays are written to satisfy all of them, so a denial usually means a value
was overridden. Check the constraint and the workload's labels/spec:

```bash
kubectl get constraints
kubectl -n demo get events --field-selector reason=FailedCreate
```

Common causes and fixes:
- *allowed-registries / disallow-latest-tag* — the image must be
  `ghcr.io/charanvamsy26/demo-api:local` (explicit tag, allowed prefix). Don't
  retag to `:latest` or another registry.
- *required-labels* — the chart stamps `app.kubernetes.io/{name,part-of}` and
  `managed-by: Helm`; don't strip them in the overlay.
- *require-probes / require-resources / require-security-context* — keep the
  chart's probes, resource limits, `runAsNonRoot`, and `drop: [ALL]` even when
  shrinking requests.

**Grafana login fails.** The local password is `admin` / `admin`. If you
previously changed it in the UI, the value is stored in Grafana's state; delete
the Grafana pod to reset to the chart value, or look it up:
`kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo`.

**`port-forward` says service not found.** The Service names depend on the
kube-prometheus-stack release name (`kube-prometheus-stack`). List them with
`kubectl -n monitoring get svc` and substitute the actual names.

**`make demo-up` exits immediately with a tool error.** It's the preflight
check — install the named tool (see [Prerequisites](#prerequisites)) and make
sure `docker info` succeeds, then re-run.
