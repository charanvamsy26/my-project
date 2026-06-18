<!--
Thanks for contributing to eks-gitops-platform. Keep PRs focused and small where possible.
The CI gates (terraform, app-ci, helm-ci, security) must be green before merge.
-->

## Summary

<!-- What does this change do, and why? Link the issue it resolves. -->

Closes #

## Type of change

- [ ] Infrastructure (Terraform)
- [ ] Kubernetes / Helm / GitOps
- [ ] Policy (OPA Gatekeeper)
- [ ] Application (demo-api)
- [ ] CI/CD / tooling
- [ ] Documentation

## Area / blast radius

- **Environment(s):** <!-- dev / prod / both / n-a -->
- **Components touched:** <!-- e.g. eks module, ALB ingress, demo-api image -->

## How was this tested?

<!-- Commands run locally and their result. Examples:
     make tf-validate ENV=dev
     make app-test
     make kubeconform
     make policy-test
-->

## Terraform plan

<!-- For infra PRs, the `terraform` workflow posts the plan as a comment.
     Confirm the plan diff matches your intent (no unexpected destroys). -->

- [ ] Plan reviewed; no unintended `destroy` / replace
- [ ] Changes are idempotent (a second plan shows no diff)

## Checklist

- [ ] Code follows repo conventions (snake_case TF vars, kebab-case k8s/files)
- [ ] Resources have tags (`Environment`, `Project=eks-gitops-platform`, `ManagedBy=terraform`)
- [ ] No secrets, no `:latest` image tags, requests/limits set where applicable
- [ ] Docs/README updated for any new or changed behavior
- [ ] All CI checks pass (lint, tests, security scans)
