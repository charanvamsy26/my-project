# my-project — developer/operator entrypoint.
#
# Thin, discoverable wrappers around terraform / helm / docker / python so the
# same commands run locally and in CI. Run `make help` for the menu.
#
# Conventions:
#   * ENV selects the Terraform environment root: dev (default) or prod.
#   * All terraform targets operate on terraform/environments/$(ENV).
#   * Targets are .PHONY (they don't produce files of the same name).

# ---- Configuration ---------------------------------------------------------
SHELL          := /usr/bin/env bash
.SHELLFLAGS    := -euo pipefail -c
.DEFAULT_GOAL  := help

ENV            ?= dev                       # dev | prod
AWS_REGION     ?= us-east-1
TF_DIR         := terraform/environments/$(ENV)
APP_DIR        := app
HELM_DIR       := kubernetes/charts
K8S_DIR        := kubernetes/namespaces
POLICY_DIR     := policies

IMAGE          ?= ghcr.io/charanvamsy/demo-api
TAG            ?= dev
K8S_VERSION    ?= 1.30.0

.PHONY: help
help: ## Show this help.
	@grep -hE '^[a-zA-Z0-9_.-]+:.*?## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---- Formatting ------------------------------------------------------------
.PHONY: fmt
fmt: ## Format Terraform (recursive) and Python (ruff).
	terraform fmt -recursive
	@if command -v ruff >/dev/null 2>&1; then ruff format $(APP_DIR); else \
		echo "ruff not installed; skipping Python format"; fi

# ---- Terraform -------------------------------------------------------------
.PHONY: tf-init
tf-init: ## terraform init for $(ENV) (real backend).
	terraform -chdir=$(TF_DIR) init -input=false

.PHONY: tf-validate
tf-validate: ## fmt -check + validate for $(ENV) (no backend, no creds).
	terraform fmt -check -recursive
	terraform -chdir=$(TF_DIR) init -backend=false -input=false
	terraform -chdir=$(TF_DIR) validate

.PHONY: tf-plan
tf-plan: ## terraform plan for $(ENV).
	terraform -chdir=$(TF_DIR) plan -input=false -out=tfplan

.PHONY: tf-apply
tf-apply: ## terraform apply the saved plan for $(ENV).
	terraform -chdir=$(TF_DIR) apply -input=false tfplan

.PHONY: tf-lint
tf-lint: ## Run tflint against $(ENV) using repo .tflint.hcl.
	tflint --init
	tflint --chdir=$(TF_DIR) --config=$(CURDIR)/.tflint.hcl

# ---- Application (demo-api) ------------------------------------------------
.PHONY: app-test
app-test: ## Lint (ruff) + run pytest for demo-api.
	ruff check $(APP_DIR)
	cd $(APP_DIR) && pytest -q

.PHONY: app-build
app-build: ## Build the demo-api Docker image as $(IMAGE):$(TAG).
	docker build -t $(IMAGE):$(TAG) $(APP_DIR)

.PHONY: app-scan
app-scan: ## Trivy-scan the locally built image (HIGH/CRITICAL gate).
	trivy image --ignore-unfixed --severity HIGH,CRITICAL --exit-code 1 $(IMAGE):$(TAG)

# ---- Helm / Kubernetes -----------------------------------------------------
.PHONY: helm-lint
helm-lint: ## helm lint every chart under $(HELM_DIR).
	@for chart in $(HELM_DIR)/*/Chart.yaml; do \
		dir=$$(dirname "$$chart"); \
		echo "==> helm lint $$dir"; \
		helm lint --strict "$$dir"; \
	done

.PHONY: kubeconform
kubeconform: ## Render charts + validate manifests against k8s $(K8S_VERSION).
	@for chart in $(HELM_DIR)/*/Chart.yaml; do \
		dir=$$(dirname "$$chart"); \
		echo "==> validate $$dir"; \
		helm template release "$$dir" --namespace demo \
			| kubeconform -strict -summary -ignore-missing-schemas \
				-kubernetes-version $(K8S_VERSION) \
				-schema-location default \
				-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'; \
	done

# ---- Policy (OPA Gatekeeper / conftest) ------------------------------------
.PHONY: policy-test
policy-test: ## Compile Gatekeeper Rego (opa check) + run conftest tests.
	@if [ -d $(POLICY_DIR) ]; then \
		opa check $(POLICY_DIR)/conftest/policy $(POLICY_DIR)/conftest/test || true; \
		if [ -d $(POLICY_DIR)/conftest/test ]; then \
			conftest verify --policy $(POLICY_DIR)/conftest/policy --policy $(POLICY_DIR)/conftest/test; \
		fi; \
	else echo "no $(POLICY_DIR)/ directory; skipping"; fi

# ---- Meta ------------------------------------------------------------------
.PHONY: pre-commit
pre-commit: ## Run all pre-commit hooks across the repo.
	pre-commit run --all-files

.PHONY: lint
lint: tf-validate tf-lint helm-lint app-test ## Run the full local lint suite.
