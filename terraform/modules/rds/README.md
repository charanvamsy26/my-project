# module: rds

**Aurora PostgreSQL** for `eks-gitops-platform` — encrypted, private, optionally multi-AZ,
with credentials managed by AWS Secrets Manager.

## What it creates

- `aws_rds_cluster` (engine `aurora-postgresql`) + `instance_count` cluster instances.
  Instance 0 is the writer; any others are readers spread across AZs.
- **DB subnet group** built from the **private** subnets — the DB is never public.
- A dedicated **security group** that only admits the EKS node/cluster SGs you pass
  (plus optional CIDRs), on the Postgres port.
- A **KMS CMK** (rotation on) used for both storage encryption and the secret.
- A **generated master password** stored as a JSON secret in **Secrets Manager**
  (`<name>/aurora/master`) — never placed in tfvars.
- An **enhanced-monitoring IAM role** (when `monitoring_interval > 0`).

## Security properties

- `storage_encrypted = true` with a customer-managed key.
- `publicly_accessible = false` on every instance.
- `iam_database_authentication_enabled = true` — pods can auth via IRSA/IAM tokens.
- PostgreSQL logs exported to CloudWatch.
- Performance Insights encrypted with the same CMK.
- `deletion_protection` + final snapshot toggles so prod can't be casually dropped.

> The generated password lands in Terraform state as well as Secrets Manager. That
> is unavoidable for `random_password`; the protection is the encrypted, access-locked
> remote state bucket created by `bootstrap/`.

## dev vs prod

| Setting               | dev                 | prod                       |
|-----------------------|---------------------|----------------------------|
| `instance_count`      | 1 (writer only)     | 2+ (writer + reader, HA)   |
| `instance_class`      | `db.t4g.medium`     | `db.r6g.large`             |
| `deletion_protection` | `false`             | `true`                     |
| `skip_final_snapshot` | `true`              | `false`                    |
| `backup_retention_days` | 7                 | 14–35                      |

## Usage

```hcl
module "rds" {
  source = "../../modules/rds"

  name       = "eks-gitops-platform-dev"
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  database_name   = "demo"
  master_username = "dbadmin"

  instance_class = "db.t4g.medium"
  instance_count = 1

  # only the EKS data plane may connect
  allowed_security_group_ids = [module.eks.cluster_primary_security_group_id]

  deletion_protection = false
  skip_final_snapshot = true

  tags = local.tags
}
```

## Consuming the credentials from a pod

The `demo-api` Flask service reads the secret at runtime (e.g. via the AWS Secrets
& Config Provider CSI driver, External Secrets Operator, or the SDK + IRSA). The
secret JSON shape is:

```json
{ "engine": "postgres", "username": "...", "password": "...",
  "host": "...", "port": 5432, "dbname": "demo" }
```

## Outputs

`writer_endpoint`, `reader_endpoint`, `port`, `database_name`, `master_username`,
`security_group_id`, `secret_arn`, `secret_name`, `cluster_arn`, `kms_key_arn`.
