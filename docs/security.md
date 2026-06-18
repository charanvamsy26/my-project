# Security & compliance posture

`my-project` treats security as a property of the platform, not an afterthought. Controls are layered — IAM, encryption, network, admission, supply chain, and secret management each contribute, and the same intent is enforced both *shift-left* in CI and *at runtime* in the cluster. This document is the consolidated view; each area links to where it actually lives in the repo.

## Threat-model summary

| Risk | Primary control(s) |
| --- | --- |
| Over-broad cloud permissions | IRSA roles scoped to exact `namespace:serviceaccount`; keyless OIDC for CI; least-privilege node role |
| Data exposure at rest | KMS envelope encryption of k8s secrets; encrypted RDS, EBS, gp3 PVCs, and S3 state |
| Data exposure in transit | ALB HTTP→HTTPS redirect + ACM; TLS-only S3 bucket policy; in-VPC private DB |
| Vulnerable / untrusted images | Trivy scan gate; allowed-registries policy; no `:latest`; non-root runtime |
| Misconfigured infra reaching prod | Conftest + tfsec + checkov in CI; Gatekeeper admission in cluster |
| Leaked secrets in Git | gitleaks (pre-commit + CI); Secrets Manager for DB creds; ArgoCD Secret blacklist |
| Lateral movement in cluster | default-deny NetworkPolicy; restricted Pod Security Admission; dropped capabilities |
| Unaudited cluster changes | GitOps-only write path; ArgoCD AppProject RBAC; CODEOWNERS-gated reviews |

## IAM & least privilege

- **IRSA (IAM Roles for Service Accounts).** The `iam-irsa` module is a role factory that scopes every trust policy to an exact `system:serviceaccount:<namespace>:<sa>` subject using `StringEquals` — **no wildcards**. Each workload (AWS Load Balancer Controller, external-dns, Karpenter, ebs-csi) gets only the permissions it needs, shipped as least-privilege JSON/templated policies.
- **Keyless CI.** `terraform.yml` authenticates to AWS via GitHub OIDC (role `my-project-gha-terraform-plan`), so there are **no long-lived AWS keys** in GitHub. The plan job runs without credentials for static checks and only assumes the role for the plan; fork PRs are skipped to prevent credential exposure.
- **Node role.** EKS managed node groups run on a least-privilege node role rather than broad instance permissions.
- **ArgoCD RBAC.** The `my-project` AppProject defines two roles — read-only and platform-admin (with delete denied) — bound to placeholder IdP groups.

## Encryption

- **Kubernetes secrets:** KMS envelope encryption at the EKS control plane, with key rotation enabled.
- **Databases & volumes:** Aurora PostgreSQL encrypted at rest; EBS and the Prometheus/Alertmanager/Grafana gp3 PVCs encrypted.
- **State:** the Terraform state bucket is AES256-encrypted, versioned, and fronted by a **TLS-only bucket policy** with all four public-access-block flags set.
- **In transit:** the ALB Ingress redirects HTTP→HTTPS and terminates with an ACM certificate; the database lives in private subnets with IAM authentication enabled.

Conftest enforces encryption-at-rest as a gate (EBS/RDS/EKS-secrets) so an un-encrypted resource fails CI before it can be applied.

## Network security

- **Default-deny NetworkPolicy** on `demo-api`, with explicit allows only for the monitoring namespace (scrape) and ingress path — east-west traffic is denied unless declared.
- **Pod Security Admission:** the `demo` namespace runs under the **restricted** PSA profile. `gatekeeper-system` and `argocd` carry the Gatekeeper ignore annotation to avoid webhook self-deadlock.
- **Private data plane:** RDS and worker nodes sit in private subnets; only the ALB is internet-facing. Conftest also blocks `0.0.0.0/0` ingress to SSH/RDP and public S3.

## Container & workload hardening

The `demo-api` Helm chart and image are hardened end to end:
- Runs as **non-root** (uid `10001`), `readOnlyRootFilesystem`, **drop ALL** capabilities, `allowPrivilegeEscalation: false`, seccomp `RuntimeDefault`.
- Multi-stage Dockerfile — no build toolchain in the final `python:3.12-slim` runtime image.
- Resource requests/limits, liveness/readiness/startup probes, PDB, and topology spread for resilience.

## Policy-as-code (defense in depth)

Same intent, enforced twice — see [`policies/`](../policies/):

- **Runtime (OPA Gatekeeper):** 8 ConstraintTemplates + Constraints — required labels, disallow `:latest`/untagged, require CPU+memory requests/limits, `runAsNonRoot` + drop ALL caps + no privilege escalation, allowed registries (`ghcr.io/charanvamsy26` + ECR), require probes, block the `default` namespace, and an optional require-PDB. Six critical rules ship as **deny**, two as **dryrun** with a documented promotion checklist.
- **Shift-left (Conftest):** the same rules applied to Terraform plans and rendered manifests at PR time, plus IaC guardrails (no public S3, no open SSH/RDP, encryption at rest).

Both layers are verified: `opa check --strict --v1-compatible` passes clean, 26/26 Conftest unit tests pass, and `demo-api` is proven compliant (a compliant Pod yields zero violations; a deliberately bad Pod fires every rule).

**Exemptions** follow a documented three-tier model: per-constraint `excludedNamespaces` → cluster Config webhook exemptions → audited break-glass annotations.

## Secret management

- **No secrets in Git.** Database credentials are a Terraform-generated master password stored in **AWS Secrets Manager** — never written to `tfvars`. Slack webhooks and similar are documented placeholders sourced from Kubernetes Secrets.
- **Detection:** **gitleaks** runs both as a pre-commit hook and in `security.yml`, configured via `.gitleaks.toml`.
- **GitOps guardrail:** the ArgoCD AppProject blacklists `Secret` resources from plain-Git sources, so secrets can't be smuggled in through a manifest.

## Supply-chain security

- **Image build & scan:** `app-ci.yml` builds with `docker/build-push-action`, scans with **Trivy** (SARIF upload + HIGH/CRITICAL gate, `--ignore-unfixed`), and **only pushes to GHCR on `main`** — untrusted PR code never publishes an artifact.
- **No floating tags:** image tags are branch/PR/SemVer/SHA via `docker/metadata-action`; `:latest` is forbidden by policy at both layers.
- **Pinned dependencies:** ArgoCD upstream pinned to v2.13.2, Gatekeeper to v3.16.3, add-on chart versions pinned in tfvars, and all GitHub Actions version-pinned.
- **Continuous scanning:** `security.yml` runs gitleaks, **checkov**, and **trivy fs** on PR, push, a daily cron, and manually — each uploading distinct SARIF categories to GitHub code scanning.
- **IaC static analysis:** `terraform.yml` runs `fmt`/`validate`/**tflint**/**tfsec**/**checkov** with no credentials before any plan.
- **Dependency hygiene:** staggered Dependabot across GitHub Actions, the three Terraform roots, pip, and Docker.

## Auditability & change control

- **GitOps-only writes:** ArgoCD is the single continuous writer to the cluster; manual edits are reverted by `selfHeal`. Every change is a reviewable Git commit.
- **CODEOWNERS** gates reviews; PR and issue templates standardize change intent.
- **Sticky Terraform plans:** `terraform.yml` posts a single, updated plan comment per environment on each PR for reviewable infra diffs.

## Reporting a vulnerability

See [`SECURITY.md`](../SECURITY.md) for the responsible-disclosure process.
