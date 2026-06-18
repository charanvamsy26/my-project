# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-06-18

Initial public release of the production-grade EKS GitOps platform.

### Added
- **Infrastructure as Code** (`terraform/`): reusable VPC, EKS (1.30, IRSA, KMS),
  IAM/IRSA, RDS (Aurora) and add-on modules; S3 + DynamoDB remote-state bootstrap;
  isolated `dev` and `prod` environment roots.
- **Application** (`app/`): `demo-api` Flask service with `/healthz`, `/readyz`,
  `/metrics`, structured logging, fault-injection hooks, and a non-root multi-stage image.
- **Packaging** (`kubernetes/`): hardened Helm chart with security context, HPA, PDB,
  NetworkPolicy, ServiceMonitor and ALB Ingress.
- **GitOps** (`argocd/`): app-of-apps with AppProject guardrails and sync-wave-ordered children.
- **Observability** (`observability/`): kube-prometheus-stack, RED + SLO recording/alert
  rules, multi-window multi-burn-rate alerts, and Grafana dashboards.
- **Policy as code** (`policies/`): OPA Gatekeeper constraints + Conftest shift-left checks.
- **CI/CD** (`.github/workflows/`): Terraform validate/plan, app build/scan/push,
  Helm validation, security scanning (tfsec, Checkov, Trivy, gitleaks), and tag-driven releases.
- **Reliability demo**: k6 load tests (`load-test/`), chaos injection (`chaos/`), and a
  Python self-healing controller (`tools/auto-remediation/`).
- **Local demo**: one-command kind setup (`make demo-up`), Codespaces devcontainer,
  and screenshot automation.
- **Docs**: architecture, deployment, runbook, SLO and security docs, plus a project explainer PDF.

[1.0.0]: https://github.com/charanvamsy26/my-project/releases/tag/v1.0.0
