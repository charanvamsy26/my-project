#!/usr/bin/env bash
# =============================================================================
# demo.sh — the reliability demo: burn the SLO error budget, then self-heal.
# -----------------------------------------------------------------------------
# Tells the end-to-end story on the local kind cluster:
#   1. start background port-forwards (demo-api + Prometheus + Grafana)
#   2. show the HEALTHY baseline (/, /healthz, /readyz, current chaos state)
#   3. BURN the error budget: inject server-side chaos via demo-api's guarded
#      POST /admin/chaos (using chaos/scripts/induce.sh). If k6 is installed we
#      additionally drive real load with load-test/k6/burn.js so the RED panels
#      and burn-rate light up; otherwise the chaos injection alone burns budget.
#   4. start tools/auto-remediation with DRY_RUN=false so it DETECTS the burn and
#      remediates (kubectl rollout restart) — then we clear chaos and show recovery
#   5. print exactly what to watch in Grafana (the demo-api-slo-burn dashboard)
#
# Everything is cleaned up on exit (trap): port-forwards are killed and chaos is
# cleared so demo-api is left healthy.
#
# Safety: the auto-remediation step defaults to SHOWING ITS DECISION only. Set
#   REMEDIATE=true   to let it actually restart the deployment (DRY_RUN=false).
#   REMEDIATE=false  (default) runs it in DRY_RUN to print the decision it WOULD make.
#
# Usage:   local/scripts/demo.sh         (or:  make demo)
#          REMEDIATE=true local/scripts/demo.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local/scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Tunables for the demo.
REMEDIATE="${REMEDIATE:-false}"           # true -> auto-remediation mutates the cluster
BURN_ERROR_RATE="${BURN_ERROR_RATE:-0.4}" # fraction of "/" requests that 500
BURN_LATENCY_MS="${BURN_LATENCY_MS:-800}" # extra ms latency on "/" (> 500ms SLO)
BURN_SECONDS="${BURN_SECONDS:-90}"        # how long to sustain chaos before healing
USE_K6="${USE_K6:-auto}"                  # auto|true|false — drive k6 load if installed
REMEDIATOR_PID=""

cleanup() {
  local rc=$?
  hr
  log "cleanup: clearing chaos and stopping background processes"
  # Stop the remediator if we started it.
  if [[ -n "${REMEDIATOR_PID}" ]] && kill -0 "${REMEDIATOR_PID}" 2>/dev/null; then
    kill "${REMEDIATOR_PID}" 2>/dev/null || true
    wait "${REMEDIATOR_PID}" 2>/dev/null || true
  fi
  # Best-effort: clear chaos so demo-api is left HEALTHY. Needs the app port-fwd,
  # which may already be torn down — so try, but never fail cleanup on it.
  if (exec 3<>"/dev/tcp/127.0.0.1/${APP_PORT}") 2>/dev/null; then
    exec 3>&- 2>/dev/null || true
    CHAOS_ADMIN_TOKEN="${CHAOS_ADMIN_TOKEN}" BASE_URL="${APP_URL}" \
      bash "${CHAOS_SCRIPTS_DIR}/recover.sh" >/dev/null 2>&1 || true
  fi
  stop_port_forwards
  hr
  exit "${rc}"
}
trap cleanup EXIT INT TERM

main() {
  hr
  log "my-project LOCAL demo — RELIABILITY STORY (burn the budget, then heal)"
  hr

  preflight curl
  require_cmd python3 "https://www.python.org/downloads/  (needed by chaos/scripts + auto-remediation)" \
    || die "python3 is required for the chaos + auto-remediation steps."
  ensure_cluster_up

  start_port_forwards
  show_baseline
  burn_budget
  run_auto_remediation
  show_recovery
  watch_in_grafana

  hr
  ok "reliability demo complete. demo-api is healthy again; port-forwards will close on exit."
  hr
}

ensure_cluster_up() {
  if ! cluster_exists; then
    die "kind cluster '${CLUSTER_NAME}' not found. Run 'make demo-up' first."
  fi
  kubectl config use-context "${KUBE_CONTEXT}" >/dev/null
  if ! kubectl --context "${KUBE_CONTEXT}" -n "${NS_APP}" get deploy "${RELEASE_APP}" >/dev/null 2>&1; then
    die "demo-api is not installed in '${NS_APP}'. Run 'make demo-up' first."
  fi
}

# ---- 1. port-forwards -------------------------------------------------------
start_port_forwards() {
  log "starting background port-forwards (app + prometheus + grafana)"
  kill_stray_port_forwards
  port_forward "${NS_APP}"        "svc/${RELEASE_APP}"                  "${APP_PORT}:${APP_PORT}" "demo-api"
  port_forward "${NS_MONITORING}" "svc/${RELEASE_MONITORING}-prometheus" "${PROM_PORT}:9090"      "prometheus"
  port_forward "${NS_MONITORING}" "svc/${RELEASE_MONITORING}-grafana"    "${GRAFANA_PORT}:80"     "grafana"
}

# ---- 2. baseline ------------------------------------------------------------
show_baseline() {
  hr
  log "HEALTHY BASELINE"
  log "GET / (root)"      ; curl_app "/"        | sed 's/^/    /' || warn "root request failed"
  log "GET /healthz"      ; curl_app "/healthz" | sed 's/^/    /' || warn "healthz failed"
  log "GET /readyz"       ; curl_app "/readyz"  | sed 's/^/    /' || warn "readyz failed"
  log "current chaos state (GET /admin/chaos)"
  CHAOS_ADMIN_TOKEN="${CHAOS_ADMIN_TOKEN}" BASE_URL="${APP_URL}" \
    python3 "${CHAOS_SCRIPTS_DIR}/chaos.py" status | sed 's/^/    /' || \
    warn "could not read chaos state (is CHAOS_ADMIN_TOKEN set on the pod?)"
  ok "baseline looks healthy."
}

# ---- 3. burn the budget -----------------------------------------------------
burn_budget() {
  hr
  log "BURNING THE ERROR BUDGET"
  log "injecting chaos via POST /admin/chaos: error_rate=${BURN_ERROR_RATE} latency_ms=${BURN_LATENCY_MS}"
  CHAOS_ADMIN_TOKEN="${CHAOS_ADMIN_TOKEN}" BASE_URL="${APP_URL}" \
    ERROR_RATE="${BURN_ERROR_RATE}" LATENCY_MS="${BURN_LATENCY_MS}" OUTAGE=false \
    bash "${CHAOS_SCRIPTS_DIR}/induce.sh" | sed 's/^/    /'
  ok "chaos injected — demo-api is now returning 5xx + added latency."

  # Optionally drive real traffic with k6 so the RED + burn-rate panels move.
  local run_k6="false"
  case "${USE_K6}" in
    true)  run_k6="true" ;;
    false) run_k6="false" ;;
    auto)  command -v k6 >/dev/null 2>&1 && run_k6="true" || run_k6="false" ;;
  esac

  if [[ "${run_k6}" == "true" ]]; then
    log "driving load with k6 (load-test/k6/burn.js) to move the RED panels"
    # Chaos is already on via /admin/chaos; run k6 WITHOUT CHAOS_TOKEN so it just
    # sends traffic (pure-overload mode) and does not toggle chaos off at teardown.
    # k6 burn.js intentionally exits non-zero (SLO thresholds fail by design) — that
    # is the success signal, so we never let it abort the demo.
    BASE_URL="${APP_URL}" k6 run \
      -e PEAK_RATE="${K6_PEAK_RATE:-60}" \
      "${K6_DIR}/burn.js" 2>&1 | sed 's/^/    /' || \
      log "k6 finished (non-zero exit is EXPECTED — the SLO thresholds were violated, which is the point)."
  else
    log "k6 not installed (or USE_K6=false) — generating a little traffic with curl so 5xx appear"
    # Fire a burst of requests so Prometheus sees errors even without k6.
    local i
    for i in $(seq 1 60); do
      curl -s -o /dev/null --max-time 3 "${APP_URL}/" || true
    done
    ok "sent 60 requests through the chaos layer."
  fi

  log "sustaining the burn for ${BURN_SECONDS}s so the burn-rate + alerts register"
  local waited=0
  while [[ "${waited}" -lt "${BURN_SECONDS}" ]]; do
    curl -s -o /dev/null --max-time 3 "${APP_URL}/" || true
    sleep 3
    waited=$((waited + 3))
  done
  ok "error budget is burning. Check Grafana now (see the watch list at the end)."
}

# ---- 4. auto-remediation ----------------------------------------------------
run_auto_remediation() {
  hr
  log "AUTO-REMEDIATION"
  # Tune for a demo: act quickly (short sustained window), small poll, restart mode,
  # pointed at the port-forwarded Prometheus and the demo deployment.
  local dry="true"
  if [[ "${REMEDIATE}" == "true" ]]; then
    dry="false"
    log "REMEDIATE=true -> running auto-remediation with DRY_RUN=false (it WILL restart demo-api on breach)"
  else
    log "REMEDIATE=false (default) -> running auto-remediation in DRY_RUN to SHOW its decision (no cluster changes)"
    log "    re-run with 'REMEDIATE=true make demo' to let it actually self-heal."
  fi

  # The remediator detects the breach via Prometheus, waits SUSTAINED_SECONDS,
  # then acts. We shorten the sustained window for the demo. It logs structured
  # decisions to stdout/stderr. We run it WITHOUT a pipe (so $! is the real PID,
  # not sed's) and stream its log via a background tail.
  log "starting tools/auto-remediation (PROM_URL=${PROM_URL}, NAMESPACE=${NS_APP}, DEPLOYMENT=${RELEASE_APP})"
  local rem_log="${TMPDIR:-/tmp}/my-project-remediator.$$.log"
  : >"${rem_log}"
  (
    cd "${REMEDIATOR_DIR}"
    DRY_RUN="${dry}" \
    PROM_URL="${PROM_URL}" \
    NAMESPACE="${NS_APP}" \
    DEPLOYMENT="${RELEASE_APP}" \
    MODE="restart" \
    BURN_QUERY_MODE="${BURN_QUERY_MODE:-burnrate}" \
    SUSTAINED_SECONDS="${REM_SUSTAINED_SECONDS:-15}" \
    POLL_SECONDS="${REM_POLL_SECONDS:-10}" \
    COOLDOWN_SECONDS="${REM_COOLDOWN_SECONDS:-60}" \
    KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}" \
    exec python3 remediator.py
  ) >"${rem_log}" 2>&1 &
  REMEDIATOR_PID=$!
  # Stream the remediator's log to the console (best-effort; killed on cleanup).
  tail -f "${rem_log}" 2>/dev/null | sed 's/^/    [remediator] /' &
  local tail_pid=$!

  # Let it run long enough to observe at least one detect->decide(->act) cycle.
  local watch_for="${REM_WATCH_SECONDS:-60}"
  log "watching the remediator for ${watch_for}s (look for a 'remediated'/'would remediate' decision)"
  local waited=0
  while [[ "${waited}" -lt "${watch_for}" ]]; do
    # Keep a trickle of traffic so the burn signal persists while it decides.
    curl -s -o /dev/null --max-time 3 "${APP_URL}/" || true
    sleep 3
    waited=$((waited + 3))
    kill -0 "${REMEDIATOR_PID}" 2>/dev/null || { warn "remediator exited early"; break; }
  done

  # Stop the remediator loop (graceful SIGTERM; it exits after the current cycle).
  if kill -0 "${REMEDIATOR_PID}" 2>/dev/null; then
    kill "${REMEDIATOR_PID}" 2>/dev/null || true
    wait "${REMEDIATOR_PID}" 2>/dev/null || true
  fi
  # Stop the log streamer and clean up the temp log.
  kill "${tail_pid}" 2>/dev/null || true
  wait "${tail_pid}" 2>/dev/null || true
  rm -f "${rem_log}" 2>/dev/null || true
  REMEDIATOR_PID=""
  ok "auto-remediation step finished."
}

# ---- 5. recovery ------------------------------------------------------------
show_recovery() {
  hr
  log "RECOVERY"
  log "clearing chaos via POST /admin/chaos (recover.sh)"
  CHAOS_ADMIN_TOKEN="${CHAOS_ADMIN_TOKEN}" BASE_URL="${APP_URL}" \
    bash "${CHAOS_SCRIPTS_DIR}/recover.sh" | sed 's/^/    /'

  log "waiting for demo-api to report healthy again"
  local i ok_count=0
  for i in $(seq 1 20); do
    if curl -fsS -o /dev/null --max-time 3 "${APP_URL}/healthz" && \
       curl -fsS -o /dev/null --max-time 3 "${APP_URL}/readyz"; then
      ok_count=$((ok_count + 1))
      [[ "${ok_count}" -ge 3 ]] && break
    else
      ok_count=0
    fi
    sleep 2
  done
  log "GET /readyz"; curl_app "/readyz" | sed 's/^/    /' || warn "readyz still failing"
  ok "demo-api recovered. The error budget will stop burning; the burn-rate falls back toward 0."
}

# ---- 6. what to watch -------------------------------------------------------
watch_in_grafana() {
  hr
  ok "WHAT TO WATCH IN GRAFANA  (${GRAFANA_URL}  — login ${GRAFANA_USER} / ${GRAFANA_PASSWORD})"
  cat <<EOF

  Open dashboard:  "demo-api — Error Budget Burn (Demo)"   (uid: demo-api-slo-burn)
  During the burn you should see, in order:
    * "Error Rate (5xx %)"            climbs as chaos injects 500s
    * "Latency p99"                   jumps above the 500ms SLO line (injected latency)
    * "Error-Budget Burn Rate"        fast(1h) + slow(6h) windows spike upward
    * "Error Budget Remaining (30d)"  ticks DOWN; the gauge drains
    * Alert "DemoApiAvailabilitySLO"  moves to Firing (Alerting -> Alert rules)
  After recovery (chaos cleared / remediation restart):
    * 5xx and p99 fall back to baseline; the burn rate returns toward 0.

  Also useful:  "demo-api — Overview (RED + SLO)"   (uid: demo-api-overview)
EOF
  hr
}

main "$@"
