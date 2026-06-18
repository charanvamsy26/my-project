# GitHub Actions Workflows

CI/CD automation for **eks-gitops-platform**. Every pipeline is least-privilege (scoped
`permissions:` per job), pins each action to a version, and is path-filtered so a
change only triggers the pipelines it can actually affect.

## Layout

| Workflow         | Triggers                                  | What it does |
|------------------|-------------------------------------------|--------------|
| `terraform.yml`  | PR touching `terraform/**`                | `fmt -check`, `init -backend=false`, `validate`, `tflint`, `tfsec` + `checkov`, then an **OIDC-authenticated `plan`** matrixed over `dev`/`prod`. Posts the plan as a sticky PR comment. |
| `app-ci.yml`     | `app/**` on PR + push to `main`           | Python setup, `ruff` lint/format, `pytest`, Docker build, **Trivy** image scan, push to `ghcr.io/charanvamsy26/demo-api` on `main` (via `GITHUB_TOKEN`). Uses `docker/build-push-action` with GHA layer cache. |
| `helm-ci.yml`    | `kubernetes/**`, `argocd/**`, `policies/**` | `helm lint`, `helm template` → **kubeconform** (k8s 1.30), and Gatekeeper `ConstraintTemplate` Rego compile via `opa check` + `conftest`. |
| `security.yml`   | PR + push to `main` + daily schedule      | **gitleaks** (secrets), **checkov** (IaC), **trivy fs** (deps/secrets/misconfig). Uploads SARIF to GitHub code scanning. |
| `release.yml`    | push of a `vX.Y.Z` tag                    | Generates SemVer release notes and publishes a GitHub Release (pre-release detection for `-rc` tags). |

## AWS OIDC role for `terraform plan`

The `plan` job authenticates to AWS with **GitHub OIDC** — no long-lived access
keys are stored in the repo. You must create an IAM role and an OIDC identity
provider once, then expose the role ARN to Actions.

### 1. Create the GitHub OIDC provider (once per account)

```text
Provider URL: https://token.actions.githubusercontent.com
Audience:     sts.amazonaws.com
```

### 2. Create the role `eks-gitops-platform-gha-terraform-plan`

Trust policy (replace `<account_id>`):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<account_id>:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:charanvamsy26/eks-gitops-platform:*" }
    }
  }]
}
```

> Tighten `sub` per environment for stronger isolation, e.g.
> `repo:charanvamsy26/eks-gitops-platform:pull_request` or
> `repo:charanvamsy26/eks-gitops-platform:ref:refs/heads/main`.

Permissions: attach a policy granting **read access for plan** plus read/write to
the remote-state backend:

- S3: `s3:GetObject`, `s3:PutObject`, `s3:ListBucket` on
  `eks-gitops-platform-tfstate-<account_id>`.
- DynamoDB: `dynamodb:GetItem`, `PutItem`, `DeleteItem` on table
  `eks-gitops-platform-tf-locks` (state locking).
- Plus the AWS read permissions Terraform needs to refresh resources (EKS, VPC,
  IAM read, etc.). Start from `ReadOnlyAccess` and add the few state-backend
  writes above; grant apply permissions to a *separate* role used only by a
  protected deploy pipeline.

### 3. Wire the ARN into Actions

Add a **repository variable** (Settings → Secrets and variables → Actions →
Variables):

```text
AWS_PLAN_ROLE_ARN = arn:aws:iam::<account_id>:role/eks-gitops-platform-gha-terraform-plan
```

The workflow reads it as `${{ vars.AWS_PLAN_ROLE_ARN }}`. The `plan` job also
**skips for fork PRs** so untrusted code can never assume the role.

## Required repo settings

- **Permissions → Workflow permissions:** "Read repository contents" (default).
  Each workflow elevates only what it needs (`packages: write`,
  `id-token: write`, `security-events: write`, `pull-requests: write`).
- **Code scanning:** enabled, so SARIF from tfsec/checkov/trivy/gitleaks lands in
  the Security tab.
- **Branch protection on `main`:** require the `terraform`, `app-ci`, `helm-ci`,
  and `security` checks, plus Code Owner review.

## Action pinning & updates

Actions are pinned to release tags and bumped automatically by
`.github/dependabot.yml` (grouped `github-actions` PRs, weekly).
