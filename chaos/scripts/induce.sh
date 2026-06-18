#!/usr/bin/env bash
# =============================================================================
# induce.sh — turn ON app-level chaos for demo-api (mechanism B).
# -----------------------------------------------------------------------------
# Thin, dependency-free wrapper around chaos.py that POSTs to demo-api's guarded
# /admin/chaos endpoint. Faults flow through the app's own instrumentation, so
# they burn the SLO error budget and show up on the dashboards/alerts.
#
# Required env:
#   CHAOS_ADMIN_TOKEN   shared token the demo-api pod was deployed with (NOT
#                       stored in this repo). Mismatch -> 401; unset on the pod
#                       -> 404 (endpoint disabled).
# Optional env (with defaults):
#   BASE_URL            demo-api base URL          (default http://localhost:8000)
#   ERROR_RATE          fraction of "/" that 500s  (default 0.5)
#   LATENCY_MS          extra ms latency on "/"    (default 500)
#   OUTAGE              "true" to force /readyz 503 (default false)
#
# Safety: chaos.py refuses BASE_URLs that look like production unless
# --i-know-what-im-doing is passed. NEVER run against prod. See ../README.md.
#
# Examples:
#   export CHAOS_ADMIN_TOKEN=dev-secret
#   ./induce.sh                                  # 50% errors + 500ms latency
#   ERROR_RATE=0.2 LATENCY_MS=0 ./induce.sh      # 20% errors, no added latency
#   OUTAGE=true ERROR_RATE=0 LATENCY_MS=0 ./induce.sh   # readiness outage only
#
# Reverse it with: ./recover.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${CHAOS_ADMIN_TOKEN:?CHAOS_ADMIN_TOKEN must be set (the demo-api chaos token)}"
ERROR_RATE="${ERROR_RATE:-0.5}"
LATENCY_MS="${LATENCY_MS:-500}"
OUTAGE="${OUTAGE:-false}"

# Translate OUTAGE -> chaos.py flag (--outage / --no-outage).
# Lowercase via tr for portability (macOS ships bash 3.2, which lacks ${var,,}).
OUTAGE_LC="$(printf '%s' "${OUTAGE}" | tr '[:upper:]' '[:lower:]')"
if [[ "${OUTAGE_LC}" == "true" || "${OUTAGE_LC}" == "1" ]]; then
  OUTAGE_FLAG="--outage"
else
  OUTAGE_FLAG="--no-outage"
fi

echo ">> inducing chaos: error_rate=${ERROR_RATE} latency_ms=${LATENCY_MS} outage=${OUTAGE}"
exec python3 "${SCRIPT_DIR}/chaos.py" set \
  --rate "${ERROR_RATE}" \
  --ms "${LATENCY_MS}" \
  ${OUTAGE_FLAG} \
  "$@"
