# eks-gitops-platform — Terraform Infrastructure

Production-grade reference platform on **AWS** provisioned entirely with **Terraform**.
This directory is the single source of truth for all cloud infrastructure: networking
(VPC), the EKS clusters, IAM/IRSA roles, the Aurora PostgreSQL data tier, and the
cluster add-ons that the Kubernetes/GitOps layer depends on.

> Region: **us-east-1** · AZs: **us-east-1a / us-east-1b / us-east-1c** · Kubernetes **1.30**
> Terraform **>= 1.6** · AWS provider **~> 5.x**

---

## Repository layout

```
terraform/
├── README.md                  # you are here
├── bootstrap/                 # one-time: creates the S3 state bucket + DynamoDB lock table
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── versions.tf
│   └── README.md
├── modules/                   # reusable, environment-agnostic building blocks
│   ├── vpc/                   # 3-AZ VPC, public/private subnets, NAT, EKS subnet tags
│   ├── eks/                   # EKS control plane, OIDC/IRSA, managed nodes, core addons
│   ├── iam-irsa/              # reusable IRSA role factory + the platform's standard roles
│   ├── rds/                   # Aurora PostgreSQL (encrypted, multi-AZ, Secrets Manager)
│   └── eks-addons/            # Helm-based add-ons (AWS LB Controller, metrics-server)
└── environments/             # per-environment root modules (the things you `apply`)
    ├── dev/                   # cheaper: single NAT, smaller nodes, single-AZ-ish RDS
    └── prod/                  # HA: NAT per AZ, larger nodes, multi-AZ Aurora
```

### Why this shape?

- **Modules contain no environment-specific values.** Everything that differs between
  `dev` and `prod` (sizes, counts, CIDRs, HA toggles) is a `variable`, set in each
  environment's `terraform.tfvars`. This keeps the modules genuinely reusable and makes
  the diff between environments small and auditable.
- **Each environment is its own root module with its own state.** A mistake in `dev`
  can never affect `prod` state. Backends are keyed per environment.
- **`versions.tf` / `providers.tf` live per environment** (and per module's `versions.tf`
  for required-provider constraints). Provider *configuration* (region, default tags)
  belongs to the root module that owns the AWS credentials, not to shared modules —
  shared modules only declare `required_providers`.

---

## Prerequisites

| Tool        | Version    | Notes                                              |
|-------------|------------|----------------------------------------------------|
| Terraform   | >= 1.6     | `tfenv` recommended to pin the version             |
| AWS CLI     | >= 2.x     | Configured credentials with admin-ish bootstrap rights |
| kubectl     | >= 1.30    | To talk to the cluster after `apply`               |
| helm        | >= 3.14    | Used by `eks-addons` provider                      |

Authenticate to AWS however your org prefers (SSO profile, assumed role, static keys
for local dev). All commands below assume `AWS_PROFILE` / `AWS_REGION` are set, e.g.:

```bash
export AWS_PROFILE=eks-gitops-platform-admin
export AWS_REGION=us-east-1
```

---

## 1. Bootstrap the remote state backend (run once per AWS account)

Terraform needs somewhere to store state *before* it can manage anything. The
`bootstrap/` stack creates that backend and is itself stored **locally** (its state
file is tiny and rarely changes — committing it or storing it in a secure location is
fine). See `bootstrap/README.md` for the full rationale.

```bash
cd bootstrap
terraform init
terraform apply
# Note the outputs: state_bucket_name and lock_table_name
```

This creates:

- **S3 bucket** `eks-gitops-platform-tfstate-<account_id>` — versioned, SSE encrypted,
  public access fully blocked, with a lifecycle policy on old versions.
- **DynamoDB table** `eks-gitops-platform-tf-locks` — used for state locking (PAY_PER_REQUEST).

The `<account_id>` suffix guarantees global S3-name uniqueness without leaking which
account it belongs to in a guessable way.

---

## 2. Provision an environment

Each environment is initialized against the shared backend with an environment-specific
state key. The `backend.tf` in each env already points at the bucket/table created above.

```bash
cd environments/dev      # or environments/prod

# First time only — copy and fill in the example tfvars
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars  # set account_id and any placeholders (ACM ARN, etc.)

terraform init           # downloads providers, configures the S3 backend
terraform plan           # review the change set
terraform apply          # create/update infrastructure
```

After `apply`, wire up `kubectl`:

```bash
aws eks update-kubeconfig --region us-east-1 --name eks-gitops-platform-dev   # or eks-gitops-platform-prod
kubectl get nodes
```

The cluster name, OIDC issuer, and IRSA role ARNs are all surfaced as outputs so the
GitOps/Kubernetes layer (ArgoCD app-of-apps, AWS LB Controller, external-dns, Karpenter,
ebs-csi) can consume them.

---

## Environment differences (dev vs prod)

| Concern             | dev                        | prod                              |
|---------------------|----------------------------|-----------------------------------|
| Cluster name        | `eks-gitops-platform-dev`           | `eks-gitops-platform-prod`                 |
| NAT gateways        | single (cost saving)       | one per AZ (HA)                   |
| Node group size     | smaller (`t3.large`), 2-4  | larger (`m5.xlarge`), 3-9        |
| Aurora              | 1 instance (Serverless-ish)| writer + reader, multi-AZ         |
| Deletion protection | off                        | on                                |
| Control-plane logs  | api, audit                 | api, audit, authenticator, etc.   |

---

## Conventions

- **Terraform variables:** `snake_case`. **K8s/file names:** `kebab-case`.
- **Tags everywhere:** every resource carries `Project = eks-gitops-platform`,
  `Environment = <env>`, `ManagedBy = terraform` via the provider `default_tags` block.
- **No `:latest` images, no hardcoded secrets.** RDS credentials are generated and
  stored in AWS Secrets Manager; volumes/state/secrets are encrypted at rest.
- **Least privilege IAM.** IRSA roles are scoped per workload, not a shared node role.

---

## Destroying

Tear down in reverse dependency order (environments first, then bootstrap last — and
only destroy bootstrap if you truly want to delete all state history):

```bash
cd environments/dev && terraform destroy
# bootstrap is intentionally left in place; deleting it loses state history.
```

> The state bucket has versioning + (optionally) a deny on deletion. Empty it
> deliberately before destroying `bootstrap`.
