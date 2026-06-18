# Deployment runbook

End-to-end procedure to stand up `eks-gitops-platform` from nothing to a running, GitOps-managed `demo-api` on EKS. This is the long-form companion to the README Quickstart. All commands target **`us-east-1`**; the example uses the **`dev`** environment.

## 0. Prerequisites

| Tool | Version | Purpose |
| --- | --- | --- |
| `terraform` | >= 1.6 | Provision AWS infrastructure |
| `aws` CLI | v2 | Authentication, `update-kubeconfig` |
| `kubectl` | matches k8s 1.30 | Cluster interaction |
| `helm` | >= 3.12 | Chart rendering / debugging |
| `argocd` CLI | >= 2.13 | Inspect Applications |

You also need: an AWS account with permissions to create VPC/EKS/IAM/RDS/S3/DynamoDB/KMS, and a registered ACM certificate (or accept that the ALB Ingress provisions without HTTPS until you supply one). The container image `ghcr.io/charanvamsy26/demo-api` is published by `app-ci.yml` on pushes to `main`.

> Sanity check before you start: `aws sts get-caller-identity` should return the account you intend to deploy into.

## 1. Bootstrap remote state (one-time per account)

Terraform needs somewhere durable to keep state before the main stacks exist. The bootstrap stack creates it.

```bash
cd terraform/bootstrap
terraform init
terraform apply
```

Record the outputs — in particular the bucket name `eks-gitops-platform-tfstate-<account_id>` and the lock table `eks-gitops-platform-tf-locks`. The bucket is versioned and AES256-encrypted with all public access blocked; `force_destroy` defaults to `false` so state history is protected.

## 2. Configure the environment backend and variables

```bash
cd ../environments/dev
```

1. Open `backend.tf` and replace `<account_id>` with your real account id (backends can't use variables, so this is hardcoded once).
2. Copy and adjust variables:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Review the defaults. Notably, `endpoint_public_access_cidrs` defaults to `0.0.0.0/0` for convenience — **lock it to your office/VPN range** for anything non-throwaway.

## 3. Provision infrastructure

```bash
terraform init        # configures the S3 backend + DynamoDB lock
terraform plan        # review: VPC, EKS eks-gitops-platform-dev, RDS, IRSA roles, add-ons
terraform apply
```

Equivalent via Make (defaults to `ENV=dev`):

```bash
make tf-init
make tf-plan
make tf-apply
```

This creates the VPC, the `eks-gitops-platform-dev` EKS cluster (k8s 1.30), the Aurora PostgreSQL cluster, the IRSA roles, and EKS add-ons. Expect ~15–20 minutes for the EKS control plane and node groups.

## 4. Get cluster access

```bash
aws eks update-kubeconfig --name eks-gitops-platform-dev --region us-east-1
kubectl get nodes        # nodes should be Ready
```

## 5. Install ArgoCD and the AppProject

ArgoCD itself is the bootstrap dependency for GitOps; install it (and the `eks-gitops-platform` AppProject guardrails) via the pinned kustomize base:

```bash
kubectl apply -k argocd/install/
kubectl -n argocd rollout status deploy/argocd-server
```

(Optional) log in to the ArgoCD API/UI:

```bash
argocd admin initial-password -n argocd       # initial admin password
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
argocd login localhost:8080 --username admin --insecure
```

## 6. Apply the root app-of-apps

This is the only Application a human applies by hand. ArgoCD takes over from here.

```bash
kubectl apply -f argocd/bootstrap/root-app.yaml
argocd app list
```

You should see `root` plus four children: the observability stack, Gatekeeper, the AWS Load Balancer Controller, and `demo-api`.

## 7. Watch it converge

ArgoCD syncs in waves: **observability + policy (wave 0)** → **AWS LB Controller (wave 1)** → **demo-api (wave 2)**.

```bash
argocd app get root --refresh
watch kubectl get applications -n argocd        # all -> Synced / Healthy
kubectl -n monitoring get pods                  # Prometheus / Grafana / Alertmanager
kubectl -n gatekeeper-system get pods           # Gatekeeper controller + audit
kubectl -n demo get pods                        # demo-api
```

## 8. Verify the workload

```bash
kubectl -n demo get ingress demo-api            # ADDRESS = ALB hostname (once provisioned)
ALB=$(kubectl -n demo get ingress demo-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Host header matches the chart's placeholder domain
curl -s -H "Host: demo-api.example.com" "http://$ALB/"        # hello payload
curl -s -H "Host: demo-api.example.com" "http://$ALB/healthz" # {"status":"ok"}
curl -s -H "Host: demo-api.example.com" "http://$ALB/readyz"  # ready / not-ready
```

Confirm Prometheus is scraping it:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
# In the Prometheus UI: Status -> Targets -> demo-api should be UP
```

## 9. Promote to prod

The prod path is identical, with these differences:
- Work in `terraform/environments/prod/` (cluster `eks-gitops-platform-prod`, larger nodes, NAT per AZ, multi-AZ Aurora, deletion protection on).
- The `demo-api` Application uses `values-prod.yaml` and the prod cluster — see `argocd/apps/README.md`.

```bash
cd terraform/environments/prod
# edit backend.tf (<account_id>) and terraform.tfvars
terraform init && terraform plan && terraform apply
aws eks update-kubeconfig --name eks-gitops-platform-prod --region us-east-1
```

## 10. Day-2: making changes

Once bootstrapped, you almost never `kubectl apply` again:
- **App change** → PR to `app/` → `app-ci.yml` tests/scans, pushes a new image tag to GHCR on merge → bump the tag in `values.yaml` → ArgoCD syncs.
- **Platform change** → PR editing a chart/values/Application → ArgoCD reconciles.
- **Infra change** → PR to `terraform/` → `terraform.yml` posts a sticky plan comment per environment → apply after review.

## Troubleshooting

| Symptom | Likely cause | Action |
| --- | --- | --- |
| `terraform init` backend error | `<account_id>` not replaced in `backend.tf` | Set the real account id; re-init. |
| Nodes never `Ready` | Subnet/IGW/NAT routing or IAM node role | Check the VPC module outputs and node role; `kubectl describe node`. |
| Application stuck `Progressing` | Wave dependency not Healthy yet | Inspect the earlier wave (`argocd app get <child>`); CRDs/webhook must exist first. |
| demo-api pod `Pending`/admission denied | Gatekeeper deny constraint | `kubectl get events -n demo`; the chart is designed to pass all deny constraints — check overrides. |
| Ingress has no ADDRESS | LB controller not Healthy or missing IRSA | Verify wave-1 app and the `aws-load-balancer-controller` IRSA role. |
| ArgoCD reverts your manual edit | `selfHeal: true` (working as intended) | Make the change in Git, not the cluster. |

Teardown is covered in the README under **Cost & teardown**.
