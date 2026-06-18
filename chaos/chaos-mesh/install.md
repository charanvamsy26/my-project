# Installing Chaos Mesh (pinned) into `chaos-testing`

[Chaos Mesh](https://chaos-mesh.org/) is the **cluster-native** fault-injection
engine used by this reliability demo. It runs as a controller plus a per-node
DaemonSet (`chaos-daemon`) that can kill pods, shape network traffic, and proxy
HTTP for the workloads you target with its CRDs (`PodChaos`, `NetworkChaos`,
`HTTPChaos`, ...).

This file is the **runbook** for installing it. The experiment manifests next to
it (`pod-kill.yaml`, `network-latency.yaml`, `http-fault.yaml`) are what you
`kubectl apply` once Chaos Mesh is running.

> Mechanism A of two. This needs a real cluster with privileged DaemonSet
> capability (EKS, or kind/minikube). If you are on a laptop and only want to
> burn the error budget, you can skip Chaos Mesh entirely and use **mechanism B**
> — the app-level driver in `../scripts/` that pokes the demo-api `/admin/chaos`
> endpoint. See `../README.md`.

---

## Pinned versions

We pin everything; never track a moving tag (the same discipline Gatekeeper
enforces on app images via `disallow-latest-tag`).

| Component        | Version  |
| ---------------- | -------- |
| Chaos Mesh chart | `2.6.3`  |
| Chaos Mesh app   | `v2.6.3` |
| Namespace        | `chaos-testing` |

> Bump deliberately: change the version below, re-run, and note it in the PR.
> Check the upstream release notes before moving major/minor versions.

---

## Prerequisites

- `kubectl` context pointed at the **target** cluster (dev — **never prod**, see
  the safety note in `../README.md`).
- `helm` v3.
- A container runtime Chaos Mesh supports. On EKS the default is `containerd`,
  whose socket is `/run/containerd/containerd.sock` (set below). For Docker or
  CRI-O, change `chaosDaemon.runtime` / `chaosDaemon.socketPath` accordingly.

Confirm the runtime before installing:

```bash
kubectl get nodes -o wide \
  -o custom-columns=NAME:.metadata.name,RUNTIME:.status.nodeInfo.containerRuntimeVersion
# e.g. containerd://1.7.x  -> runtime=containerd, socket=/run/containerd/containerd.sock
```

---

## Install (Helm, recommended)

```bash
# 1) Create the dedicated namespace. Chaos Mesh's own pods need elevated
#    privileges (hostPath to the CRI socket, hostNetwork on the daemon), so it
#    lives in its OWN namespace, NOT in `demo`, and NOT under the restricted Pod
#    Security Admission profile that `demo` enforces.
kubectl create namespace chaos-testing --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace chaos-testing \
  app.kubernetes.io/part-of=eks-gitops-platform \
  pod-security.kubernetes.io/enforce=privileged --overwrite

# 2) Add the chart repo and pin the version.
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update

# 3) Install, pinned, into chaos-testing.
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-testing \
  --version 2.6.3 \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
  --set dashboard.create=true \
  --wait

# 4) Verify the controller, daemon (one per node), and dashboard are up.
kubectl -n chaos-testing get pods
kubectl get crds | grep chaos-mesh.org   # podchaos, networkchaos, httpchaos, ...
```

### Open the dashboard (optional, read-only review of running experiments)

```bash
kubectl -n chaos-testing port-forward svc/chaos-dashboard 2333:2333
# then browse http://localhost:2333
```

The dashboard is convenient but **declarative YAML in this directory is the
source of truth** — apply experiments with `kubectl apply`, not by hand in the
UI, so they are reviewable and reversible via git.

---

## Why a separate, privileged namespace (and why that's OK)

`demo` enforces the restricted Pod Security Admission profile and is subject to
the project's Gatekeeper constraints (non-root, drop ALL caps, RO rootfs, ghcr/ECR
images, ...). Chaos Mesh's `chaos-daemon` legitimately violates those (it mounts
the host CRI socket and uses host networking to manipulate target containers), so
it must NOT run in `demo`. Installing it into its own `chaos-testing` namespace
keeps the blast radius of those privileges contained and your app namespace
clean. The **experiments** it runs still *target* pods in `demo` via label
selectors — the privileged daemon acts on them from outside.

---

## Uninstall / clean up

Removing Chaos Mesh stops all injection immediately (the CRDs and their
controllers go away). Always delete running experiments first so nothing is left
mid-fault if you later reinstall.

```bash
# Delete any experiments we applied (id-empotent; ignore "not found").
kubectl -n demo delete -f pod-kill.yaml -f network-latency.yaml -f http-fault.yaml --ignore-not-found

# Then remove Chaos Mesh and the namespace.
helm uninstall chaos-mesh -n chaos-testing
kubectl delete namespace chaos-testing
```

---

## Running the experiments

See each manifest's header comment for what it does and how to scope/verify it.
All three are scoped to `app.kubernetes.io/name=demo-api` in namespace `demo` and
use **short durations** so they auto-recover. Quick reference:

```bash
# Apply (start the fault) — short, self-terminating experiments.
kubectl -n demo apply -f pod-kill.yaml          # PodChaos: kill one demo-api pod
kubectl -n demo apply -f network-latency.yaml   # NetworkChaos: +200ms latency
kubectl -n demo apply -f http-fault.yaml         # HTTPChaos: respond 500 to "/"

# Watch the effect.
kubectl -n demo get pods -w
kubectl -n demo describe podchaos demo-api-pod-kill

# Stop early / clean up (deleting the object reverts the fault).
kubectl -n demo delete -f pod-kill.yaml -f network-latency.yaml -f http-fault.yaml
```
