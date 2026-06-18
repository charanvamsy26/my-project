#!/usr/bin/env bash
# =============================================================================
# capture-screenshots.sh — capture REAL Grafana panel images for the docs.
# -----------------------------------------------------------------------------
# Port-forwards Grafana, then uses Grafana's server-side RENDER API
# (/render/d-solo/<uid>/... and /render/d/<uid>/...) with the local admin creds
# to save PNGs of the demo-api dashboards into docs/img/:
#
#     docs/img/slo-burn.png      <- demo-api — Error Budget Burn (uid demo-api-slo-burn)
#     docs/img/app-overview.png  <- demo-api — Overview (RED + SLO) (uid demo-api-overview)
#
# The render API needs Grafana's IMAGE-RENDERER (the grafana-image-renderer plugin
# or the companion renderer service). kube-prometheus-stack does NOT ship it by
# default, so this script:
#   * checks whether rendering works (a tiny probe render)
#   * if it works: saves real PNGs for both dashboards
#   * if it does NOT: prints a clear, friendly message documenting the manual step
#     (open the dashboard, Share -> Export -> Save as PNG, or enable the renderer)
#     and exits 0 so it never breaks `make`.
#
# Run AFTER `make demo-up` (and ideally during/after `make demo` so the panels have
# data). Usage:  local/scripts/capture-screenshots.sh   (or:  make demo-screenshots)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local/scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Render parameters.
RENDER_WIDTH="${RENDER_WIDTH:-1600}"
RENDER_HEIGHT="${RENDER_HEIGHT:-900}"
RENDER_FROM="${RENDER_FROM:-now-1h}"     # time range to render
RENDER_TO="${RENDER_TO:-now}"
RENDER_TZ="${RENDER_TZ:-UTC}"

cleanup() { stop_port_forwards; }
trap cleanup EXIT INT TERM

main() {
  hr
  log "my-project LOCAL demo — capture Grafana screenshots into docs/img/"
  hr

  preflight curl
  ensure_grafana_up

  mkdir -p "${DOCS_IMG_DIR}"
  kill_stray_port_forwards
  port_forward "${NS_MONITORING}" "svc/${RELEASE_MONITORING}-grafana" "${GRAFANA_PORT}:80" "grafana"

  if ! renderer_available; then
    print_manual_fallback
    exit 0
  fi
  ok "Grafana image renderer is available — capturing real panel images."

  # Full-dashboard renders (most useful for the README hero images).
  render_dashboard "demo-api-slo-burn"  "demo-api-error-budget-burn" "${DOCS_IMG_DIR}/slo-burn.png"
  render_dashboard "demo-api-overview"  "demo-api-overview"          "${DOCS_IMG_DIR}/app-overview.png"

  hr
  ok "saved:"
  ok "  ${DOCS_IMG_DIR}/slo-burn.png"
  ok "  ${DOCS_IMG_DIR}/app-overview.png"
  hr
}

ensure_grafana_up() {
  if ! cluster_exists; then
    die "kind cluster '${CLUSTER_NAME}' not found. Run 'make demo-up' first."
  fi
  kubectl config use-context "${KUBE_CONTEXT}" >/dev/null
  if ! kubectl --context "${KUBE_CONTEXT}" -n "${NS_MONITORING}" get deploy "${RELEASE_MONITORING}-grafana" >/dev/null 2>&1; then
    die "Grafana is not installed in '${NS_MONITORING}'. Run 'make demo-up' first."
  fi
}

# Probe whether the render API actually returns an image. A failed/absent renderer
# typically returns a 500 with a JSON error ("Rendering failed: ... plugin not
# found") instead of a PNG, so we check the Content-Type and magic bytes.
renderer_available() {
  local probe="${TMPDIR:-/tmp}/grafana-render-probe.$$"
  local code
  code="$(curl -s -o "${probe}" -w '%{http_code}' \
    -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
    "${GRAFANA_URL}/render/d-solo/demo-api-slo-burn/probe?panelId=1&width=200&height=120&from=${RENDER_FROM}&to=${RENDER_TO}" \
    2>/dev/null || true)"
  local ok_render="false"
  if [[ "${code}" == "200" ]] && [[ -s "${probe}" ]]; then
    # PNG magic number is \x89PNG.
    if head -c4 "${probe}" 2>/dev/null | grep -q 'PNG'; then
      ok_render="true"
    fi
  fi
  rm -f "${probe}" 2>/dev/null || true
  [[ "${ok_render}" == "true" ]]
}

# render_dashboard <uid> <slug> <out.png>
render_dashboard() {
  local uid="$1" slug="$2" out="$3"
  log "rendering dashboard '${uid}' -> ${out}"
  local url="${GRAFANA_URL}/render/d/${uid}/${slug}?orgId=1&from=${RENDER_FROM}&to=${RENDER_TO}&width=${RENDER_WIDTH}&height=${RENDER_HEIGHT}&tz=${RENDER_TZ}&kiosk"
  local code
  code="$(curl -s -o "${out}" -w '%{http_code}' \
    -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" "${url}" 2>/dev/null || true)"
  if [[ "${code}" == "200" ]] && head -c4 "${out}" 2>/dev/null | grep -q 'PNG'; then
    ok "rendered ${out} ($(wc -c <"${out}" | tr -d ' ') bytes)"
  else
    rm -f "${out}" 2>/dev/null || true
    warn "render for '${uid}' returned HTTP ${code} (not a PNG); skipping ${out}."
  fi
}

print_manual_fallback() {
  hr
  warn "Grafana image renderer is NOT available on this local stack."
  cat >&2 <<EOF

  kube-prometheus-stack does not ship the server-side renderer by default, so the
  /render API cannot produce PNGs here. Real screenshots can still be captured
  manually (this is the documented fallback):

  OPTION A — capture by hand (fastest):
    1. make demo-up   &&   make demo        # bring up + drive the burn so panels have data
    2. kubectl --context ${KUBE_CONTEXT} -n ${NS_MONITORING} \\
         port-forward svc/${RELEASE_MONITORING}-grafana ${GRAFANA_PORT}:80
    3. Open ${GRAFANA_URL}  (login ${GRAFANA_USER} / ${GRAFANA_PASSWORD})
    4. Dashboard "demo-api — Error Budget Burn (Demo)" (uid demo-api-slo-burn):
         take a screenshot and save it as  docs/img/slo-burn.png
       Dashboard "demo-api — Overview (RED + SLO)" (uid demo-api-overview):
         save it as  docs/img/app-overview.png

  OPTION B — enable the renderer, then re-run this script:
    helm upgrade ${RELEASE_MONITORING} ${HELM_CHART_PROM} \\
      -n ${NS_MONITORING} \\
      -f ${PROM_VALUES_CLOUD} -f ${PROM_VALUES_LOCAL} \\
      --set grafana.imageRenderer.enabled=true
    # wait for the renderer pod, then:
    local/scripts/capture-screenshots.sh

  No PNGs were written. Exiting 0 so this does not fail your build.
EOF
  hr
}

main "$@"
