# environment: dev

The **dev** root module — a cost-optimized but realistic copy of the production
platform. Cluster name: **`eks-gitops-platform-dev`**.

## What it provisions

```
module.vpc            10.0.0.0/16, 3 AZs, SINGLE NAT gateway, flow logs
module.eks            eks-gitops-platform-dev (K8s 1.30), t3.large nodes (2-4), IRSA, core addons
module.*_irsa         least-privilege IRSA roles: LB controller, external-dns, ebs-csi, karpenter
module.rds            Aurora PostgreSQL, single instance (db.t4g.medium), Secrets Manager
module.eks_addons     AWS Load Balancer Controller + metrics-server (Helm)
```

## Cost-saving choices (vs prod)

| Choice                        | Effect |
|-------------------------------|--------|
| `single_nat_gateway = true`   | one NAT instead of three (~$65/mo saved) |
| `t3.large` nodes, 2-4         | smaller/fewer instances |
| `instance_count = 1` (Aurora) | single writer, no reader |
| `cluster_log_types = [api, audit]` | fewer CloudWatch log streams |
| `deletion_protection = false` | easy teardown |

These trade availability for cost — acceptable for a non-prod environment.

## Usage

```bash
# 0. ensure bootstrap has run and you've set <account_id> in backend.tf

# 1. first time only
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars        # override anything you like

# 2. standard workflow
terraform init
terraform plan
terraform apply

# 3. talk to the cluster
$(terraform output -raw configure_kubectl)
kubectl get nodes
```

## Outputs you'll use

- `configure_kubectl` — ready-to-run `aws eks update-kubeconfig` command.
- `irsa_role_arns` — map of role ARNs to annotate ServiceAccounts in the GitOps repo
  (AWS LB Controller, external-dns, ebs-csi, Karpenter).
- `karpenter_node_instance_profile_name` / `karpenter_interruption_queue_name` —
  feed the Karpenter `EC2NodeClass` and controller config.
- `rds_writer_endpoint` / `rds_secret_arn` — for `demo-api` to reach the database.

## Files

| File                       | Purpose |
|----------------------------|---------|
| `backend.tf`               | S3 + DynamoDB remote state (key `environments/dev/...`) |
| `providers.tf`             | AWS + Helm providers, default tags |
| `versions.tf`              | Terraform & provider constraints |
| `variables.tf`             | All tunables (with dev defaults) |
| `main.tf`                  | Module wiring |
| `outputs.tf`               | Surfaced values |
| `terraform.tfvars.example` | Copy to `terraform.tfvars` |

## Tearing down

```bash
terraform destroy
```

Because `deletion_protection = false` and `skip_final_snapshot = true`, dev tears
down cleanly. (Prod intentionally does not.)
