# Security Policy

`my-project` is a reference platform that takes security seriously at every layer — IAM least privilege, encryption at rest and in transit, policy-as-code, image scanning, and a GitOps-only change path. For the full posture, see [`docs/security.md`](docs/security.md).

## Supported versions

This is a reference/portfolio repository; security fixes are applied to the `main` branch. There are no long-lived release branches — always base work on, and consume from, `main`.

| Branch | Supported |
| --- | --- |
| `main` | Yes |
| tags / older | No (cut from `main` at a point in time) |

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Report privately using one of:

1. **GitHub Security Advisories** — open a private report via the repository's **Security → Report a vulnerability** tab (preferred; keeps disclosure coordinated).
2. **Email** — contact the maintainer at the address on the GitHub profile of [`charanvamsy26`](https://github.com/charanvamsy26).

Please include:
- A clear description of the issue and its impact.
- Steps to reproduce (or a proof of concept).
- Affected component/path (e.g. a Terraform module, the Helm chart, a workflow, a policy).
- Any suggested remediation.

## What to expect

| Stage | Target |
| --- | --- |
| Acknowledgement of your report | within 3 business days |
| Initial assessment & severity triage | within 7 business days |
| Status updates | at least every 7 days until resolved |
| Coordinated disclosure | after a fix is merged, by mutual agreement |

We follow responsible/coordinated disclosure: please give us a reasonable window to remediate before any public disclosure. Credit is gladly given to reporters who wish to be named.

## Scope

In scope — anything in this repository:
- Terraform modules and environment roots (`terraform/`).
- The `demo-api` application and image (`app/`).
- Helm chart and Kubernetes manifests (`kubernetes/`).
- GitOps configuration (`argocd/`).
- Observability and policy configuration (`observability/`, `policies/`).
- CI/CD workflows and repo hygiene (`.github/`).

Out of scope:
- Vulnerabilities in upstream third-party software (ArgoCD, Gatekeeper, kube-prometheus-stack, AWS services) — report those to their respective projects. We pin versions and will upgrade promptly once an upstream fix exists.
- Findings that require already-compromised credentials or privileged cluster access.
- The intentional placeholders documented in the repo (e.g. `demo-api.example.com`, example tfvars, placeholder Slack webhooks) — these are not real secrets.

## Our safeguards (context for reporters)

This repo already enforces, in CI and at runtime:
- gitleaks secret scanning, Trivy image/filesystem scanning, checkov and tfsec IaC scanning.
- OPA Gatekeeper admission control + Conftest shift-left policy.
- Least-privilege IRSA, keyless OIDC for CI, KMS encryption, and a GitOps-only write path.

If you find a gap in any of these, that's exactly the kind of report we want. Thank you for helping keep the project secure.
