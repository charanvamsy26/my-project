#!/usr/bin/env bash
# =============================================================================
# down.sh — tear the local demo down: delete the kind cluster + stray port-forwards.
# -----------------------------------------------------------------------------
# Idempotent: safe to run whether or not the cluster exists. Steps:
#   1. kill any leftover kubectl port-forwards for this cluster (from up/demo runs)
#   2. delete the kind cluster `eks-gitops-platform-local` (no-op if it's already gone)
#
# The locally-built image (ghcr.io/charanvamsy26/demo-api:local) is left in your
# Docker engine so a subsequent `make demo-up` rebuilds/reuses it quickly. Pass
# REMOVE_IMAGE=true to also delete the local image.
#
# Usage:  local/scripts/down.sh        (or:  make demo-down)
#         REMOVE_IMAGE=true local/scripts/down.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local/scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

REMOVE_IMAGE="${REMOVE_IMAGE:-false}"

main() {
  hr
  log "eks-gitops-platform LOCAL demo — tear-down (cluster=${CLUSTER_NAME})"
  hr

  # kind + docker are the only hard requirements for teardown.
  require_cmd kind "https://kind.sigs.k8s.io/docs/user/quick-start/" || \
    die "kind not found; cannot delete the cluster."

  # 1. Kill stray port-forwards first so nothing holds the cluster's API open.
  log "stopping any leftover kubectl port-forwards"
  kill_stray_port_forwards
  # Also catch the generic localhost mappings the demo uses.
  pkill -f "kubectl.*port-forward.*${APP_PORT}:${APP_PORT}" 2>/dev/null || true
  pkill -f "kubectl.*port-forward.*${PROM_PORT}:9090" 2>/dev/null || true
  pkill -f "kubectl.*port-forward.*${GRAFANA_PORT}:80" 2>/dev/null || true
  ok "port-forwards cleaned up."

  # 2. Delete the cluster (idempotent).
  if cluster_exists; then
    log "deleting kind cluster '${CLUSTER_NAME}'"
    kind delete cluster --name "${CLUSTER_NAME}"
    ok "kind cluster deleted."
  else
    ok "kind cluster '${CLUSTER_NAME}' does not exist; nothing to delete."
  fi

  # 3. Optionally remove the locally-built image.
  if [[ "${REMOVE_IMAGE}" == "true" ]]; then
    if command -v docker >/dev/null 2>&1 && docker image inspect "${IMAGE_REF}" >/dev/null 2>&1; then
      log "removing local image ${IMAGE_REF}"
      docker image rm "${IMAGE_REF}" >/dev/null 2>&1 || warn "could not remove ${IMAGE_REF}"
      ok "local image removed."
    else
      ok "local image ${IMAGE_REF} not present; nothing to remove."
    fi
  else
    log "kept local image ${IMAGE_REF} (set REMOVE_IMAGE=true to delete it)."
  fi

  hr
  ok "local demo torn down."
  hr
}

main "$@"
