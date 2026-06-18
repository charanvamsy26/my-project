# Contributing to eks-gitops-platform

Thanks for your interest. This repository is a production-grade reference platform, and contributions are held to the same bar as the rest of it: everything is code, everything is reviewed, and everything is validated by CI before it merges. This guide gets you productive quickly and keeps changes coherent with the project's shared conventions.

## Ground rules

- **GitOps is the write path to clusters.** Don't `kubectl apply` changes you intend to keep — change the manifest/chart/values in Git and let ArgoCD reconcile. Manual edits are reverted by `selfHeal`.
- **Use the shared constants.** Region `us-east-1`, project tag `eks-gitops-platform`, image `ghcr.io/charanvamsy26/demo-api`, port `8000`, namespaces `demo` / `monitoring` / `gatekeeper-system` / `argocd`, Kubernetes `1.30`. Coherence across components depends on these being identical everywhere.
- **Naming:** kebab-case for Kubernetes resources and filenames; snake_case for Terraform variables.
- **Tag everything** with `Environment`, `Project=eks-gitops-platform`, and `ManagedBy=terraform`.
- **No secrets in Git, ever.** Use AWS Secrets Manager or Kubernetes Secrets sourced at runtime. gitleaks will catch you; the ArgoCD AppProject blocks Git-sourced `Secret` resources.

## Prerequisites

Install the tools relevant to what you're touching:

| Area | Tools |
| --- | --- |
| Terraform | `terraform >= 1.6`, `tflint`, `tfsec`, `checkov` |
| App | `python 3.12`, `ruff`, `pytest`, `docker`, `trivy` |
| Helm / k8s | `helm >= 3.12`, `kubeconform`, `kubectl` |
| Policy | `opa`, `conftest` |
| Hygiene | `pre-commit`, `gitleaks`, `yamllint` |

Install the git hooks once:

```bash
pre-commit install
```

## Development workflow

1. **Branch** off `main` (`feat/...`, `fix/...`, `docs/...`).
2. **Make the change** in the right place (see the README feature matrix and per-directory READMEs).
3. **Validate locally** using the Makefile — these mirror CI:

   ```bash
   make help          # list all targets
   make fmt           # terraform fmt + ruff format
   make lint          # tf-validate + tf-lint + helm-lint + app-test
   make app-test      # ruff check + pytest for demo-api
   make tf-plan       # ENV=dev (default) or ENV=prod
   make helm-lint     # helm lint --strict
   make kubeconform   # render charts + validate against k8s 1.30
   make policy-test   # opa check + conftest
   make pre-commit    # run all hooks across the repo
   ```

4. **Open a PR.** Fill out the PR template. CI runs the relevant workflow(s):
   - `terraform.yml` — fmt/validate/tflint/tfsec/checkov + a keyless OIDC plan per environment, posted as a sticky comment.
   - `app-ci.yml` — ruff + pytest + Docker build + Trivy scan (push to GHCR only on `main`).
   - `helm-ci.yml` — helm lint, kubeconform, Gatekeeper Rego compilation, conftest.
   - `security.yml` — gitleaks, checkov, trivy fs.
5. **Get review.** CODEOWNERS routes reviewers; address feedback; keep the branch green.

## Change-type checklists

**Terraform**
- Run `make tf-validate tf-lint` and review the plan in the PR comment.
- Keep modules reusable; put environment specifics in `environments/{dev,prod}`.
- Don't break the dev/prod state isolation (per-env backend keys).
- New cloud resources must be encrypted and least-privilege — Conftest/tfsec will enforce this.

**App (`demo-api`)**
- Add/extend tests in `app/tests/`; `pytest` must pass.
- Keep metric label cardinality bounded (route templates, not raw paths).
- Preserve the liveness vs readiness contract (`/healthz` process-only; `/readyz` may probe the DB and return 503 without crashing).
- The image must remain non-root and pass the Trivy HIGH/CRITICAL gate.

**Helm / Kubernetes**
- `helm lint --strict` and `kubeconform` (k8s 1.30) must pass across default/dev/prod overlays.
- The chart must continue to satisfy every Gatekeeper **deny** constraint (non-root, limits, probes, approved registry, no `:latest`, required labels).
- Don't set `replicas` when autoscaling is enabled — let the HPA own it.

**Observability**
- Edit the **Sloth SLO source** (`observability/slo/slo.yaml`), then regenerate `slo-rules.yaml`; commit both together.
- New alerts need `severity`, `team`, clear `summary`/`description`, and a `runbook_url`.
- Recording/SLO rules must exclude probe/scrape paths and guard against `0/0`.

**Policy**
- New Gatekeeper rules need a ConstraintTemplate **and** a Constraint; new Conftest rules need passing/failing fixture tests.
- `opa check --strict --v1-compatible` and `conftest verify` must pass.
- Document any new exemption against the three-tier model.

## Adding a platform component (GitOps)

Because of the app-of-apps pattern, adding a component is a single-file PR: add an ArgoCD `Application` under `argocd/apps/`, set the correct `sync-wave`, and point it at the right path/namespace/values. The `root` Application picks it up automatically. See `argocd/apps/README.md`.

## Commit & PR conventions

- Imperative, scoped commit subjects (e.g. `terraform: add gp3 default for RDS`).
- Keep PRs focused and reviewable; update the relevant README/docs in the same PR.
- All CI checks green and at least one CODEOWNER approval before merge.

## Reporting security issues

Do **not** open a public issue for vulnerabilities — follow [`SECURITY.md`](SECURITY.md).
