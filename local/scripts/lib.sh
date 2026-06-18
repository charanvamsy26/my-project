#!/usr/bin/env bash
# =============================================================================
# lib.sh — shared helpers for the my-project LOCAL demo scripts.
# -----------------------------------------------------------------------------
# Sourced by up.sh / demo.sh / capture-screenshots.sh / down.sh. NOT meant to be
# run directly. Provides:
#   * the shared LOCAL-DEMO CONSTANTS (cluster name, namespaces, image, ports,
#     release names, Grafana creds) so every script interlocks on the same values
#   * logging helpers (log / warn / err / die / hr)
#   * require_cmd / preflight — preflight checks for docker/kind/kubectl/helm
#   * port_forward / stop_port_forwards — background kubectl port-forward helpers
#
# Conventions: bash, `set -euo pipefail` is set by the *callers* (so that sourcing
# this file never silently changes a caller's shell options unexpectedly), but we
# guard our own logic to be safe under it.
# =============================================================================

# ---- Shared LOCAL-DEMO CONSTANTS (single source of truth) -------------------
# Override any of these from the environment before calling a script if needed,
# but the defaults are what the whole demo is wired to.
CLUSTER_NAME="${CLUSTER_NAME:-my-project-local}"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-${CLUSTER_NAME}}"

# Namespaces.
NS_APP="${NS_APP:-demo}"
NS_MONITORING="${NS_MONITORING:-monitoring}"
NS_GATEKEEPER="${NS_GATEKEEPER:-gatekeeper-system}"

# demo-api image: explicit non-:latest tag under ghcr.io/charanvamsy26/ so it
# PASSES the repo's Gatekeeper allowed-registries + disallow-latest constraints.
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/charanvamsy26/demo-api}"
IMAGE_TAG="${IMAGE_TAG:-local}"
IMAGE_REF="${IMAGE_REPO}:${IMAGE_TAG}"

# Helm release names. The monitoring release name MUST be `kube-prometheus-stack`
# (the ServiceMonitor/rule selectors and demo-api's `release:` label depend on it).
RELEASE_APP="${RELEASE_APP:-demo-api}"
RELEASE_MONITORING="${RELEASE_MONITORING:-kube-prometheus-stack}"
RELEASE_GATEKEEPER="${RELEASE_GATEKEEPER:-gatekeeper}"

# Local Grafana admin credentials (set in the LOCAL kube-prometheus-stack values
# overlay only — clearly a local-only credential).
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"

# Chaos admin token — must match config.CHAOS_ADMIN_TOKEN in the demo-api LOCAL
# overlay (local/helm-values/demo-api.local.yaml). Throwaway local-only secret.
CHAOS_ADMIN_TOKEN="${CHAOS_ADMIN_TOKEN:-local-demo-token}"

# Port-forward ports (host side) and the URLs they expose.
APP_PORT="${APP_PORT:-8000}"
PROM_PORT="${PROM_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
APP_URL="http://localhost:${APP_PORT}"
PROM_URL="http://localhost:${PROM_PORT}"
GRAFANA_URL="http://localhost:${GRAFANA_PORT}"

# kube-prometheus-stack Helm repo.
HELM_REPO_PROM_NAME="${HELM_REPO_PROM_NAME:-prometheus-community}"
HELM_REPO_PROM_URL="${HELM_REPO_PROM_URL:-https://prometheus-community.github.io/helm-charts}"
HELM_CHART_PROM="${HELM_CHART_PROM:-prometheus-community/kube-prometheus-stack}"

# Gatekeeper Helm repo.
HELM_REPO_GK_NAME="${HELM_REPO_GK_NAME:-gatekeeper}"
HELM_REPO_GK_URL="${HELM_REPO_GK_URL:-https://open-policy-agent.github.io/gatekeeper/charts}"
HELM_CHART_GK="${HELM_CHART_GK:-gatekeeper/gatekeeper}"

# Repo paths (resolved relative to this file so scripts work from any CWD).
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${LIB_DIR}/../.." && pwd)"
APP_DIR="${REPO_ROOT}/app"
CHART_DIR="${REPO_ROOT}/kubernetes/charts/demo-api"
KIND_CONFIG="${REPO_ROOT}/local/kind/kind-config.yaml"
NS_DIR="${REPO_ROOT}/kubernetes/namespaces"
PROM_VALUES_CLOUD="${REPO_ROOT}/observability/kube-prometheus-stack/values.yaml"
PROM_VALUES_LOCAL="${REPO_ROOT}/local/helm-values/kube-prometheus-stack.local.yaml"
APP_VALUES_BASE="${CHART_DIR}/values.yaml"
APP_VALUES_LOCAL="${REPO_ROOT}/local/helm-values/demo-api.local.yaml"
GK_TEMPLATES_DIR="${REPO_ROOT}/policies/gatekeeper/templates"
GK_CONSTRAINTS_DIR="${REPO_ROOT}/policies/gatekeeper/constraints"
DASHBOARDS_DIR="${REPO_ROOT}/observability/grafana/dashboards"
DOCS_IMG_DIR="${REPO_ROOT}/docs/img"
CHAOS_SCRIPTS_DIR="${REPO_ROOT}/chaos/scripts"
K6_DIR="${REPO_ROOT}/load-test/k6"
REMEDIATOR_DIR="${REPO_ROOT}/tools/auto-remediation"

# ---- Logging ----------------------------------------------------------------
# Colours only when stdout is a TTY (so logs piped to files stay clean).
if [[ -t 1 ]]; then
  _C_RESET="\033[0m"; _C_BLUE="\033[34m"; _C_GREEN="\033[32m"
  _C_YELLOW="\033[33m"; _C_RED="\033[31m"; _C_BOLD="\033[1m"
else
  _C_RESET=""; _C_BLUE=""; _C_GREEN=""; _C_YELLOW=""; _C_RED=""; _C_BOLD=""
fi

log()  { printf "%b==>%b %s\n" "${_C_BLUE}${_C_BOLD}" "${_C_RESET}" "$*"; }
ok()   { printf "%b ok%b %s\n" "${_C_GREEN}${_C_BOLD}" "${_C_RESET}" "$*"; }
warn() { printf "%b!! %b %s\n" "${_C_YELLOW}${_C_BOLD}" "${_C_RESET}" "$*" >&2; }
err()  { printf "%bxx %b %s\n" "${_C_RED}${_C_BOLD}" "${_C_RESET}" "$*" >&2; }
hr()   { printf "%b%s%b\n" "${_C_BOLD}" "------------------------------------------------------------------------" "${_C_RESET}"; }

die() { err "$*"; exit 1; }

# ---- Preflight: required tools ----------------------------------------------
# require_cmd <command> [install-hint]
require_cmd() {
  local cmd="$1" hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "required command not found: '${cmd}'"
    [[ -n "$hint" ]] && err "  install hint: ${hint}"
    return 1
  fi
  return 0
}

# preflight [extra-cmd ...] — verify docker/kind/kubectl/helm (+ any extras) and
# that the Docker daemon is actually reachable. Exits non-zero with hints.
preflight() {
  local missing=0
  require_cmd docker "https://docs.docker.com/desktop/  (Docker Desktop or 'brew install --cask docker')" || missing=1
  require_cmd kind   "https://kind.sigs.k8s.io/docs/user/quick-start/  ('brew install kind' or 'go install sigs.k8s.io/kind@latest')" || missing=1
  require_cmd kubectl "https://kubernetes.io/docs/tasks/tools/  ('brew install kubectl')" || missing=1
  require_cmd helm   "https://helm.sh/docs/intro/install/  ('brew install helm')" || missing=1

  # Any extra required commands passed by the caller (e.g. curl, python3).
  local extra
  for extra in "$@"; do
    require_cmd "$extra" || missing=1
  done

  [[ "$missing" -eq 0 ]] || die "missing prerequisites (see hints above); install them and re-run."

  # Docker daemon must be running, otherwise kind/build fail with confusing errors.
  if ! docker info >/dev/null 2>&1; then
    die "Docker is installed but the daemon is not reachable. Start Docker Desktop (or your engine) and re-run."
  fi
  ok "preflight passed: docker, kind, kubectl, helm present and Docker is running."
}

# ---- kind helpers -----------------------------------------------------------
cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"
}

# ---- Port-forward helpers ---------------------------------------------------
# Background kubectl port-forwards tracked in PF_PIDS so we can clean them up via
# a trap. Each caller should:  trap stop_port_forwards EXIT INT TERM
PF_PIDS=()

# port_forward <namespace> <resource> <local:remote> [label]
# Starts `kubectl port-forward` in the background, records its PID, and waits
# until the local port is actually accepting connections (no blind sleep).
port_forward() {
  local ns="$1" res="$2" mapping="$3" label="${4:-$res}"
  local lport="${mapping%%:*}"

  log "port-forward ${label}: ${ns}/${res} (${mapping})"
  # -2 keeps output quiet but still surfaces errors; run detached in background.
  kubectl --context "${KUBE_CONTEXT}" -n "${ns}" port-forward "${res}" "${mapping}" \
    >/dev/null 2>&1 &
  local pid=$!
  PF_PIDS+=("${pid}")

  # Wait (bounded) for the port to come up.
  local i
  for i in $(seq 1 30); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      die "port-forward for ${ns}/${res} exited early; is the resource Ready?"
    fi
    if (exec 3<>"/dev/tcp/127.0.0.1/${lport}") 2>/dev/null; then
      exec 3>&- 2>/dev/null || true
      ok "port-forward ${label} ready on localhost:${lport}"
      return 0
    fi
    sleep 1
  done
  die "timed out waiting for port-forward ${label} on localhost:${lport}"
}

# stop_port_forwards — kill every port-forward we started. Safe to call multiple
# times and from an EXIT trap.
stop_port_forwards() {
  local pid
  for pid in "${PF_PIDS[@]:-}"; do
    [[ -n "${pid}" ]] || continue
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
  PF_PIDS=()
}

# kill_stray_port_forwards — best-effort cleanup of any leftover kubectl
# port-forwards for THIS cluster's context (e.g. from a crashed previous run).
kill_stray_port_forwards() {
  # pkill may not match across all platforms; ignore failures.
  pkill -f "kubectl.*--context ${KUBE_CONTEXT}.*port-forward" 2>/dev/null || true
  pkill -f "kubectl.*port-forward.*svc/${RELEASE_APP}" 2>/dev/null || true
}

# ---- App helper: hit the demo-api over the port-forward ----------------------
# curl_app <path> [curl-args...]
curl_app() {
  local path="$1"; shift || true
  curl -fsS --max-time 5 "$@" "${APP_URL}${path}"
}
