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

IMAGE          ?= ghcr.io/charanvamsy26/demo-api
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

# ============================================================================
# LOCAL DEMO (kind, NO AWS) — one-command portfolio demo
# ----------------------------------------------------------------------------
# Stands up the whole platform on a local kind cluster (`my-project-local`):
# demo-api + kube-prometheus-stack + OPA Gatekeeper, then drives a reliability
# story (burn the SLO error budget, then self-heal) and captures dashboards.
#
# Everything lives under local/ (scripts + kind config + helm overlays). These
# targets are thin wrappers around local/scripts/*.sh — see `make demo-help`.
# Prereqs: docker, kind, kubectl, helm (the scripts preflight-check them).
#
#   make demo-up          # create cluster + build/load image + install all + wait
#   make demo             # burn the error budget, run auto-remediation, recover
#   make demo-screenshots # capture real Grafana panel PNGs into docs/img/
#   make demo-down        # delete the kind cluster + stray port-forwards
# ============================================================================
LOCAL_SCRIPTS := local/scripts

.PHONY: demo-up
demo-up: ## [demo] Stand up the local kind demo (cluster, image, monitoring, gatekeeper, demo-api).
	$(LOCAL_SCRIPTS)/up.sh

.PHONY: demo
demo: ## [demo] Run the reliability demo: burn the SLO budget, auto-remediate, recover.
	$(LOCAL_SCRIPTS)/demo.sh

.PHONY: demo-screenshots
demo-screenshots: ## [demo] Capture real Grafana dashboard PNGs into docs/img/ (graceful fallback if no renderer).
	$(LOCAL_SCRIPTS)/capture-screenshots.sh

.PHONY: demo-down
demo-down: ## [demo] Tear down the local demo: delete the kind cluster + port-forwards.
	$(LOCAL_SCRIPTS)/down.sh

.PHONY: demo-help
demo-help: ## [demo] Show the local-demo quickstart (what each demo-* target does).
	@echo ""
	@echo "  my-project LOCAL DEMO (kind cluster 'my-project-local', NO AWS)"
	@echo "  --------------------------------------------------------------"
	@echo "  Prereqs: docker, kind, kubectl, helm  (the scripts preflight-check these)"
	@echo ""
	@echo "  1) make demo-up          Create the kind cluster, build + 'kind load' the"
	@echo "                           demo-api image (ghcr.io/charanvamsy26/demo-api:local),"
	@echo "                           create namespaces, install kube-prometheus-stack +"
	@echo "                           OPA Gatekeeper (+ policies) + demo-api, wait for all"
	@echo "                           rollouts, then print the port-forward URLs."
	@echo ""
	@echo "  2) make demo             Start port-forwards, show the healthy baseline, inject"
	@echo "                           chaos to BURN the SLO error budget, run the"
	@echo "                           auto-remediation controller, then recover. Set"
	@echo "                           REMEDIATE=true to let it actually restart demo-api."
	@echo ""
	@echo "  3) make demo-screenshots Capture real Grafana panels (demo-api-slo-burn +"
	@echo "                           demo-api-overview) into docs/img/ via the render API,"
	@echo "                           with a documented manual fallback if no image-renderer."
	@echo ""
	@echo "  4) make demo-down        Delete the kind cluster and any leftover port-forwards."
	@echo ""
	@echo "  Access after demo-up (each in its own terminal):"
	@echo "    demo-api   : kubectl -n demo port-forward svc/demo-api 8000:8000        -> http://localhost:8000"
	@echo "    Grafana    : kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 -> http://localhost:3000"
	@echo "    Prometheus : kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090"
	@echo "    Grafana login: admin / admin  (LOCAL-ONLY credential)"
	@echo ""
