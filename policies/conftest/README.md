# Conftest policies (`conftest/`)

CI-time **shift-left** policies that fail a pull request *before* bad infrastructure
or workloads ever reach a cluster. Built on [Conftest](https://www.conftest.dev/)
(OPA/Rego). These are the pre-merge twin of the in-cluster Gatekeeper constraints:
**same intent, two layers** (defense in depth).

| Conftest catches at PR time | Gatekeeper backstops at apply time |
| --------------------------- | ---------------------------------- |
| Public S3, `0.0.0.0/0` → SSH, unencrypted EBS/RDS/EKS — **in the Terraform plan** | (Gatekeeper can't see AWS resources) |
| `:latest`, wrong registry, no limits, root, no probes — **in rendered k8s manifests** | The same rules, enforced on live admission |

## Layout

```
conftest/
├── README.md
├── policy/                          # Rego rules (the `deny` / `warn` sets)
│   ├── terraform_s3.rego            # no public S3; require encryption + lock-down
│   ├── terraform_security_groups.rego  # no 0.0.0.0/0 to 22/3389; warn on broad exposure
│   ├── terraform_encryption.rego    # EBS/RDS/EKS encryption-at-rest
│   └── kubernetes.rego              # workload guardrails (mirrors Gatekeeper)
├── test/                            # Rego unit tests for every policy
│   ├── kubernetes_test.rego
│   ├── terraform_s3_test.rego
│   ├── terraform_security_groups_test.rego
│   └── terraform_encryption_test.rego
└── examples/                        # runnable sample manifests
    ├── demo-api-deployment.yaml     # COMPLIANT (golden) — must pass
    └── bad-deployment.yaml          # NON-COMPLIANT — must fail
```

## Conventions

- A rule in the **`deny`** set fails the run (CI red). A rule in **`warn`** prints a
  warning but does not fail (use `--fail-on-warn` to make warnings blocking).
- Terraform policies consume the JSON plan, not `.tf` source. Manifest policies
  consume rendered YAML (post-Helm/Kustomize), not templates.
- Package names map to namespaces; pass `-p policy` so Conftest loads `policy/`.

## Running locally

### 1. Kubernetes manifests

```bash
# A single rendered manifest:
conftest test -p policy examples/demo-api-deployment.yaml      # passes
conftest test -p policy examples/bad-deployment.yaml           # fails (expected)

# Real workloads — render Helm first, then pipe in:
helm template demo-api ./charts/demo-api | conftest test -p policy -
```

### 2. Terraform plans

```bash
cd terraform/environments/prod
terraform init
terraform plan -out tfplan.binary
terraform show -json tfplan.binary > plan.json

conftest test -p ../../../policies/conftest/policy plan.json
```

### 3. Run the policy unit tests

The policies ship with their own tests (a regression net that guarantees demo-api
keeps passing as rules evolve):

```bash
# From policies/conftest/
conftest verify -p policy test
# or, equivalently, with the OPA CLI:
opa test policy test -v
```

## What each policy enforces

### `terraform_s3.rego`
For every created/updated `aws_s3_bucket`:
- **deny** a public ACL (`public-read`, `public-read-write`, `authenticated-read`)
- **deny** a bucket with no fully-locked `aws_s3_bucket_public_access_block`
  (all four `block_*` flags `true`)
- **deny** a bucket with no explicit `aws_s3_bucket_server_side_encryption_configuration`
- **warn** when versioning is not enabled

### `terraform_security_groups.rego`
Across inline ingress, `aws_security_group_rule`, and
`aws_vpc_security_group_ingress_rule`:
- **deny** ingress from `0.0.0.0/0` or `::/0` to admin ports (22 SSH, 3389 RDP)
- **warn** on any non-web (`80`/`443`) port open to the world

### `terraform_encryption.rego`
- **deny** `aws_ebs_volume` without `encrypted = true`
- **deny** `aws_db_instance` / `aws_rds_cluster` without `storage_encrypted = true`
- **deny** `aws_eks_cluster` without `encryption_config` (KMS envelope encryption for
  Kubernetes Secrets)

### `kubernetes.rego`
For workload kinds (Deployment/StatefulSet/DaemonSet/Job/CronJob/Pod/ReplicaSet):
- **deny** `:latest` / untagged images
- **deny** images not from `ghcr.io/charanvamsy/` or `<account_id>.dkr.ecr.us-east-1.amazonaws.com/`
- **deny** containers missing cpu/memory **requests and limits**
- **deny** containers not `runAsNonRoot`, not dropping `ALL` caps, or allowing
  privilege escalation
- **deny** app containers missing liveness/readiness probes
- **deny** workloads in the `default` namespace

> **demo-api passes:** `examples/demo-api-deployment.yaml` is the golden file and
> `test/kubernetes_test.rego` asserts `count(deny) == 0` for it (and for the ECR-mirror
> image variant). Keep this in sync with the demo-api Helm chart.

## CI integration (GitHub Actions sketch)

```yaml
# .github/workflows/policy.yml (owned by the CI builder; shown for reference)
name: policy
on: [pull_request]
jobs:
  conftest:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: open-policy-agent/conftest-action@v0   # or install the binary
      # Unit-test the policies themselves
      - run: conftest verify -p policies/conftest/policy policies/conftest/test
      # Lint rendered manifests
      - run: helm template demo-api charts/demo-api | conftest test -p policies/conftest/policy -
      # Lint the Terraform plan (plan.json produced by an earlier job/step)
      - run: conftest test -p policies/conftest/policy plan.json
```
