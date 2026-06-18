# bootstrap — Terraform remote state backend

Creates the resources that every other Terraform root module in `eks-gitops-platform`
depends on for **remote state** and **state locking**:

| Resource          | Name                                   | Purpose                          |
|-------------------|----------------------------------------|----------------------------------|
| S3 bucket         | `eks-gitops-platform-tfstate-<account_id>`      | Stores `.tfstate` per environment |
| DynamoDB table    | `eks-gitops-platform-tf-locks`                   | Distributed lock (`LockID` hash)  |

## Why this stack uses local state

This is a classic chicken-and-egg: Terraform's S3 backend can only be used once
the bucket and lock table exist. So **bootstrap stores its own state locally**.
That's fine — this stack is tiny, changes rarely, and contains no secrets. Keep
the resulting `terraform.tfstate` somewhere durable (a secrets vault, or commit it
to the repo; it only describes the bucket and table).

## Security properties

- **Versioning** enabled → recover from a bad/corrupted state push.
- **SSE (AES256)** on the bucket and the DynamoDB table → encrypted at rest.
- **Public access fully blocked** (all four S3 PAB flags = true).
- **Bucket policy denies non-TLS access** (`aws:SecureTransport = false`).
- **Lifecycle rule** expires non-current versions after 90 days (configurable) and
  aborts stale multipart uploads.
- **PITR** enabled on the lock table.
- **`force_destroy = false`** by default so a stray `terraform destroy` cannot wipe
  state history.

## Usage

```bash
terraform init
terraform plan
terraform apply

# capture these for the environment backend.tf files
terraform output state_bucket_name   # eks-gitops-platform-tfstate-123456789012
terraform output lock_table_name     # eks-gitops-platform-tf-locks
terraform output account_id          # 123456789012
```

Then plug the values into `environments/<env>/backend.tf` (already templated — only
the `<account_id>` placeholder needs to match your real account).

## Files

| File           | Contents                                              |
|----------------|-------------------------------------------------------|
| `versions.tf`  | Terraform & provider version constraints (local state)|
| `variables.tf` | Region, project, force-destroy guard, retention days  |
| `main.tf`      | Provider, S3 bucket + hardening, DynamoDB lock table  |
| `outputs.tf`   | Bucket/table names + account id for downstream configs|

## Destroying (rare)

Only destroy this after every environment is gone. Because `force_destroy` defaults
to `false`, you must first empty the bucket (delete all object versions) manually,
then `terraform destroy`. This friction is intentional.
