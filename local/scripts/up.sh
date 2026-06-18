#!/usr/bin/env bash
# =============================================================================
# up.sh — stand up the WHOLE my-project local demo on a kind cluster (NO AWS).
# -----------------------------------------------------------------------------
# Idempotent end-to-end bring-up:
#   1. preflight (docker/kind/kubectl/helm present, Docker running)
#   2. create the kind cluster `my-project-local` (skip if it already exists)
#   3. build the demo-api image and `kind load docker-image` it into the cluster
#   4. create namespaces (demo / monitoring / gatekeeper-system)
#   5. install kube-prometheus-stack into `monitoring` with BOTH the cloud values
#      and the local overlay
#   6. install OPA Gatekeeper into `gatekeeper-system`, then apply the constraint
#      TEMPLATES, wait for their CRDs to register, then apply the CONSTRAINTS
#   7. install the demo-api chart with the local overlay into `demo`
#   8. wait for every rollout, then print the port-forward URLs + Grafana login
#
# Re-runnable: every step checks current state and only does what's needed.
#
# Usage:   local/scripts/up.sh        (or:  make demo-up)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local/scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Pin the kind node image to a 1.30.x release. Overridable via KIND_NODE_IMAGE,
# but the kind-config.yaml already pins an immutable digest, so we let the config
# own the image and only use this as a fallback/override.
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-}"

# Chart version for kube-prometheus-stack. Pinned for reproducibility; override
# with PROM_CHART_VERSION=... if you need a different release.
PROM_CHART_VERSION="${PROM_CHART_VERSION:-65.5.1}"
# Gatekeeper chart version. v3.16.x is validated for k8s 1.27-1.30 (see
# policies/gatekeeper/install/README.md).
GK_CHART_VERSION="${GK_CHART_VERSION:-3.16.3}"

main() {
  hr
  log "my-project LOCAL demo — bring-up"
  log "cluster=${CLUSTER_NAME}  context=${KUBE_CONTEXT}  image=${IMAGE_REF}"
  hr

  preflight

  create_cluster
  build_and_load_image
  create_namespaces
  install_monitoring
  install_gatekeeper
  install_demo_api
  wait_for_rollouts
  print_access

  hr
  ok "local demo is UP. Next:  make demo   (run the reliability demo)"
  hr
}

# ---- 2. kind cluster --------------------------------------------------------
create_cluster() {
  log "step 1/7 — kind cluster"
  if cluster_exists; then
    ok "kind cluster '${CLUSTER_NAME}' already exists; skipping create."
  else
    log "creating kind cluster '${CLUSTER_NAME}' from ${KIND_CONFIG}"
    local args=(create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}" --wait 120s)
    if [[ -n "${KIND_NODE_IMAGE}" ]]; then
      args+=(--image "${KIND_NODE_IMAGE}")
    fi
    kind "${args[@]}"
    ok "kind cluster created."
  fi
  # Make sure kubectl talks to this cluster regardless of the user's current ctx.
  kubectl config use-context "${KUBE_CONTEXT}" >/dev/null
  kubectl --context "${KUBE_CONTEXT}" cluster-info >/dev/null
  ok "kube-context '${KUBE_CONTEXT}' is active."
}

# ---- 3. build + load image --------------------------------------------------
build_and_load_image() {
  log "step 2/7 — build + load demo-api image"
  log "docker build -t ${IMAGE_REF} ${APP_DIR}"
  docker build -t "${IMAGE_REF}" "${APP_DIR}"
  ok "image built: ${IMAGE_REF}"

  log "kind load docker-image ${IMAGE_REF} --name ${CLUSTER_NAME}"
  kind load docker-image "${IMAGE_REF}" --name "${CLUSTER_NAME}"
  ok "image side-loaded into the kind cluster (no registry pull needed)."
}

# ---- 4. namespaces ----------------------------------------------------------
create_namespaces() {
  log "step 3/7 — namespaces (demo / monitoring / gatekeeper-system)"
  # Apply the repo's declarative Namespace manifests (carry PSA + ownership
  # labels). `kubectl apply` is idempotent. The argocd namespace manifest is also
  # in this dir but harmless to apply; we apply the whole directory for fidelity
  # with the platform, except we ensure the three the demo needs exist.
  kubectl --context "${KUBE_CONTEXT}" apply -f "${NS_DIR}/demo.yaml"
  kubectl --context "${KUBE_CONTEXT}" apply -f "${NS_DIR}/monitoring.yaml"
  kubectl --context "${KUBE_CONTEXT}" apply -f "${NS_DIR}/gatekeeper-system.yaml"
  ok "namespaces applied."
}

# ---- 5. kube-prometheus-stack ----------------------------------------------
install_monitoring() {
  log "step 4/7 — kube-prometheus-stack into '${NS_MONITORING}'"

  log "helm repo add ${HELM_REPO_PROM_NAME} ${HELM_REPO_PROM_URL}"
  helm repo add "${HELM_REPO_PROM_NAME}" "${HELM_REPO_PROM_URL}" >/dev/null 2>&1 || true
  helm repo update "${HELM_REPO_PROM_NAME}" >/dev/null

  # Install/upgrade with BOTH values files: cloud baseline first, local overlay
  # second so the laptop overrides win. Release name MUST be kube-prometheus-stack.
  log "helm upgrade --install ${RELEASE_MONITORING} (chart ${PROM_CHART_VERSION})"
  helm upgrade --install "${RELEASE_MONITORING}" "${HELM_CHART_PROM}" \
    --namespace "${NS_MONITORING}" \
    --version "${PROM_CHART_VERSION}" \
    -f "${PROM_VALUES_CLOUD}" \
    -f "${PROM_VALUES_LOCAL}" \
    --kube-context "${KUBE_CONTEXT}" \
    --wait --timeout 10m
  ok "kube-prometheus-stack installed/upgraded."

  # PrometheusRules: the repo's SLO recording rules + burn-demo rules + alerts are
  # PrometheusRule CRs (namespace monitoring, label release=kube-prometheus-stack).
  # The operator auto-adopts them via ruleSelector. Apply them so the SLO/burn-rate
  # series and the DemoApi* alerts exist (the dashboard + auto-remediation need them).
  log "applying PrometheusRules (SLO + burn-demo + alerts)"
  kubectl --context "${KUBE_CONTEXT}" -n "${NS_MONITORING}" apply \
    -f "${REPO_ROOT}/observability/prometheus/rules/recording-rules.yaml" \
    -f "${REPO_ROOT}/observability/prometheus/rules/slo-rules.yaml" \
    -f "${REPO_ROOT}/observability/prometheus/rules/burn-demo-rules.yaml" \
    -f "${REPO_ROOT}/observability/prometheus/rules/alerts.yaml"
  ok "PrometheusRules applied."

  install_dashboards
}

# Wrap each Grafana dashboard JSON into a ConfigMap labelled `grafana_dashboard:
# "1"` (the sidecar discovery label) so Grafana auto-imports them — exactly what
# the GitOps layer does in dev/prod. Idempotent via `kubectl apply`.
install_dashboards() {
  log "importing Grafana dashboards via sidecar ConfigMaps"
  local json base cm_name
  for json in "${DASHBOARDS_DIR}"/*.json; do
    [[ -e "${json}" ]] || continue
    base="$(basename "${json}")"               # e.g. demo-api-slo-burn.json
    cm_name="grafana-dashboard-${base%.json}"  # e.g. grafana-dashboard-demo-api-slo-burn
    # Build the ConfigMap from the file, label it for the sidecar, annotate the
    # target folder, and apply. --dry-run=client keeps it declarative/idempotent.
    kubectl --context "${KUBE_CONTEXT}" -n "${NS_MONITORING}" \
      create configmap "${cm_name}" \
      --from-file="${base}=${json}" \
      --dry-run=client -o yaml \
      | kubectl --context "${KUBE_CONTEXT}" label --local -f - \
          grafana_dashboard=1 -o yaml \
      | kubectl --context "${KUBE_CONTEXT}" annotate --local -f - \
          grafana_folder=my-project -o yaml \
      | kubectl --context "${KUBE_CONTEXT}" apply -f -
  done
  ok "dashboard ConfigMaps applied (sidecar will import them into the 'my-project' folder)."
}

# ---- 6. Gatekeeper + policies ----------------------------------------------
install_gatekeeper() {
  log "step 5/7 — OPA Gatekeeper into '${NS_GATEKEEPER}' + policies"

  log "helm repo add ${HELM_REPO_GK_NAME} ${HELM_REPO_GK_URL}"
  helm repo add "${HELM_REPO_GK_NAME}" "${HELM_REPO_GK_URL}" >/dev/null 2>&1 || true
  helm repo update "${HELM_REPO_GK_NAME}" >/dev/null

  log "helm upgrade --install ${RELEASE_GATEKEEPER} (chart ${GK_CHART_VERSION})"
  helm upgrade --install "${RELEASE_GATEKEEPER}" "${HELM_CHART_GK}" \
    --namespace "${NS_GATEKEEPER}" \
    --version "${GK_CHART_VERSION}" \
    --kube-context "${KUBE_CONTEXT}" \
    --wait --timeout 5m

  # Control plane must be Ready before any ConstraintTemplate/Constraint applies.
  log "waiting for Gatekeeper controller + audit to be available"
  kubectl --context "${KUBE_CONTEXT}" -n "${NS_GATEKEEPER}" rollout status \
    deploy/gatekeeper-controller-manager --timeout=180s
  kubectl --context "${KUBE_CONTEXT}" -n "${NS_GATEKEEPER}" rollout status \
    deploy/gatekeeper-audit --timeout=180s
  ok "Gatekeeper control plane is Ready."

  # Apply ConstraintTemplates FIRST: each template registers a new CRD
  # (constraints.gatekeeper.sh/<Kind>). Constraints can only be created once their
  # CRD exists, so we apply templates, wait for the CRDs to be Established, THEN
  # apply the constraints.
  log "applying Gatekeeper ConstraintTemplates"
  kubectl --context "${KUBE_CONTEXT}" apply -f "${GK_TEMPLATES_DIR}"

  log "waiting for constraint CRDs to register (Established)"
  # Wait for the CRDs created by the templates to become Established. We give the
  # API a short window to create them, then `kubectl wait` on each.
  local crd
  local crds=(
    k8sallowedregistries.constraints.gatekeeper.sh
    k8sblockdefaultnamespace.constraints.gatekeeper.sh
    k8sdisallowlatesttag.constraints.gatekeeper.sh
    k8srequirepdb.constraints.gatekeeper.sh
    k8srequireprobes.constraints.gatekeeper.sh
    k8srequireresources.constraints.gatekeeper.sh
    k8srequiresecuritycontext.constraints.gatekeeper.sh
    k8srequiredlabels.constraints.gatekeeper.sh
  )
  for crd in "${crds[@]}"; do
    # Give Gatekeeper a moment to create the CRD from the template, retrying.
    local i
    for i in $(seq 1 30); do
      if kubectl --context "${KUBE_CONTEXT}" get crd "${crd}" >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
    if kubectl --context "${KUBE_CONTEXT}" get crd "${crd}" >/dev/null 2>&1; then
      kubectl --context "${KUBE_CONTEXT}" wait --for=condition=Established \
        --timeout=60s "crd/${crd}" >/dev/null 2>&1 || true
    else
      warn "constraint CRD '${crd}' not found yet; constraints apply may retry."
    fi
  done
  ok "constraint CRDs established."

  log "applying Gatekeeper Constraints"
  # Retry once: even after Established, the admission webhook for the new kind can
  # take a beat to be ready, which can transiently reject the constraint apply.
  if ! kubectl --context "${KUBE_CONTEXT}" apply -f "${GK_CONSTRAINTS_DIR}"; then
    warn "first constraints apply failed; retrying in 10s..."
    sleep 10
    kubectl --context "${KUBE_CONTEXT}" apply -f "${GK_CONSTRAINTS_DIR}"
  fi
  ok "Gatekeeper templates + constraints applied (demo-api is built to pass them)."
}

# ---- 7. demo-api ------------------------------------------------------------
install_demo_api() {
  log "step 6/7 — demo-api chart into '${NS_APP}' (local overlay)"
  helm upgrade --install "${RELEASE_APP}" "${CHART_DIR}" \
    --namespace "${NS_APP}" \
    -f "${APP_VALUES_BASE}" \
    -f "${APP_VALUES_LOCAL}" \
    --kube-context "${KUBE_CONTEXT}" \
    --wait --timeout 5m
  ok "demo-api installed/upgraded."
}

# ---- 8. rollouts + access ---------------------------------------------------
wait_for_rollouts() {
  log "step 7/7 — waiting for all rollouts"

  kubectl --context "${KUBE_CONTEXT}" -n "${NS_APP}" rollout status \
    "deploy/${RELEASE_APP}" --timeout=180s

  # kube-prometheus-stack: Prometheus + Alertmanager are StatefulSets; Grafana +
  # operator + kube-state-metrics are Deployments. Wait on the user-facing ones.
  kubectl --context "${KUBE_CONTEXT}" -n "${NS_MONITORING}" rollout status \
    "deploy/${RELEASE_MONITORING}-grafana" --timeout=300s
  # Prometheus/Alertmanager are managed by the operator as StatefulSets; wait via
  # the StatefulSet rollout (names follow the prometheus-operator convention).
  kubectl --context "${KUBE_CONTEXT}" -n "${NS_MONITORING}" rollout status \
    "statefulset/prometheus-${RELEASE_MONITORING}-prometheus" --timeout=300s || \
    warn "Prometheus StatefulSet not ready yet (it may still be initializing)."

  kubectl --context "${KUBE_CONTEXT}" -n "${NS_GATEKEEPER}" rollout status \
    deploy/gatekeeper-controller-manager --timeout=120s

  ok "all rollouts complete."
}

print_access() {
  hr
  ok "Access (each line is a separate kubectl port-forward you run in its own terminal):"
  cat <<EOF

  # demo-api  -> ${APP_URL}
  kubectl --context ${KUBE_CONTEXT} -n ${NS_APP} port-forward svc/${RELEASE_APP} ${APP_PORT}:${APP_PORT}

  # Grafana   -> ${GRAFANA_URL}     (login: ${GRAFANA_USER} / ${GRAFANA_PASSWORD}  — LOCAL-ONLY credential)
  kubectl --context ${KUBE_CONTEXT} -n ${NS_MONITORING} port-forward svc/${RELEASE_MONITORING}-grafana ${GRAFANA_PORT}:80

  # Prometheus -> ${PROM_URL}
  kubectl --context ${KUBE_CONTEXT} -n ${NS_MONITORING} port-forward svc/${RELEASE_MONITORING}-prometheus ${PROM_PORT}:9090

Then in Grafana open the dashboard:  "demo-api — Error Budget Burn (Demo)"  (uid: demo-api-slo-burn)
The reliability demo (make demo) starts these port-forwards for you automatically.
EOF
  hr
}

main "$@"
