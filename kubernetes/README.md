# Kubernetes

This directory holds the **Kubernetes-native** layer of **eks-gitops-platform** — the
manifests and Helm chart that run on the EKS clusters provisioned by Terraform
(`eks-gitops-platform-dev`, `eks-gitops-platform-prod`; Kubernetes 1.30, AWS `us-east-1`,
multi-AZ across `us-east-1a/b/c`).

It assumes the cluster, node groups, networking, and platform add-ons (AWS Load
Balancer Controller, kube-prometheus-stack, OPA Gatekeeper, ArgoCD) already
exist — those are owned by the Terraform and GitOps layers. What lives here is
the application workload and the cluster's namespace/policy scaffolding.

## Layout

```
kubernetes/
├── README.md                 # this file
├── namespaces/               # Namespace manifests (PSA + Gatekeeper labels)
│   ├── demo.yaml
│   ├── monitoring.yaml
│   ├── gatekeeper-system.yaml
│   ├── argocd.yaml
│   └── README.md
└── charts/
    └── demo-api/             # Helm chart for the reference Flask workload
        ├── Chart.yaml
        ├── values.yaml
        ├── values-dev.yaml
        ├── values-prod.yaml
        ├── templates/
        └── README.md
```

## How it fits together

```
 ┌──────────────┐    GitOps (app-of-apps)    ┌───────────────────────────┐
 │   ArgoCD     │ ─────────────────────────▶ │ namespaces/  +  demo-api  │
 │ (argocd ns)  │                            │ Helm release (demo ns)    │
 └──────────────┘                            └───────────┬───────────────┘
        ▲                                                 │
        │ syncs from Git                                  │ exposes
        │                                                 ▼
 ┌──────────────┐   scrape (ServiceMonitor)     ┌───────────────────────┐
 │ Prometheus   │ ◀──────────────────────────── │ demo-api Service/Pods │
 │ (monitoring) │                               │  + ALB Ingress        │
 └──────────────┘                               └───────────────────────┘
        ▲
        │ admission policy
 ┌──────────────┐
 │  Gatekeeper  │  enforces restricted-style policy on the demo namespace
 │(gatekeeper-  │  (non-root, RO rootfs, dropped caps, resource limits, …)
 │  system ns)  │
 └──────────────┘
```

1. **Namespaces** establish the security/policy boundaries: `demo` enforces the
   PSA `restricted` profile, while platform namespaces (`monitoring`,
   `gatekeeper-system`, `argocd`) get the permissions and Gatekeeper exemptions
   they require. See `namespaces/README.md`.
2. **demo-api** (chart in `charts/demo-api`) deploys into `demo`. It is built to
   pass the `restricted` profile and the Gatekeeper policies out of the box:
   non-root, read-only root filesystem, all capabilities dropped, resource
   requests/limits, probes, and a default-deny NetworkPolicy.
3. **ALB Ingress** (AWS Load Balancer Controller) exposes the service at
   `demo-api.example.com`; TLS terminates on the ALB with an ACM certificate.
4. **Prometheus** (kube-prometheus-stack in `monitoring`) scrapes `/metrics` via
   the chart's `ServiceMonitor`.
5. **ArgoCD** (`argocd` namespace, project `eks-gitops-platform`) reconciles all of the
   above from Git using the app-of-apps pattern.

## Quick start (manual / bootstrap)

```bash
# 1. Point kubectl at the target cluster
aws eks update-kubeconfig --name eks-gitops-platform-dev --region us-east-1

# 2. Create namespaces (PSA + policy labels)
kubectl apply -f kubernetes/namespaces/

# 3. Install demo-api (dev overlay)
helm upgrade --install demo-api kubernetes/charts/demo-api \
  -n demo \
  -f kubernetes/charts/demo-api/values.yaml \
  -f kubernetes/charts/demo-api/values-dev.yaml \
  --set image.tag=0.1.0

# 4. Verify
kubectl -n demo rollout status deployment/demo-api-demo-api
kubectl -n demo get svc,ingress,hpa,servicemonitor,pdb,networkpolicy
```

For **prod**, target `eks-gitops-platform-prod` and use `values-prod.yaml`. In steady
state, prefer letting **ArgoCD** apply these rather than running the commands
above by hand.

## Conventions

* kebab-case for files and Kubernetes object names.
* Standard labels on every object: `project=eks-gitops-platform`,
  `app.kubernetes.io/part-of=eks-gitops-platform`, `managed-by`, and `environment`.
* No `:latest` image tags — always an explicit, immutable tag.
* Security defaults are non-negotiable: least privilege, dropped capabilities,
  read-only root filesystems, network policies, and resource limits.

## Related

* Application source & Dockerfile: `../app/`
* Infrastructure (EKS, networking, IAM, state): `../terraform/`
* GitOps definitions (ArgoCD app-of-apps): managed alongside this repo's GitOps
  layer.
