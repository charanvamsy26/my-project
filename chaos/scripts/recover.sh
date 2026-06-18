#!/usr/bin/env bash
# =============================================================================
# recover.sh — turn OFF all app-level chaos for demo-api (mechanism B).
# -----------------------------------------------------------------------------
# Idempotent: POSTs the safe baseline {error_rate:0, latency_ms:0, outage:false}
# to demo-api's /admin/chaos. Safe to run any time, even if no chaos is active —
# it always converges demo-api back to healthy. Run this when a demo ends, or any
# time you're unsure what state the service is in.
#
# Required env:
#   CHAOS_ADMIN_TOKEN   shared token the demo-api pod was deployed with.
# Optional env:
#   BASE_URL            demo-api base URL (default http://localhost:8000)
#
# Example:
#   export CHAOS_ADMIN_TOKEN=dev-secret
#   ./recover.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${CHAOS_ADMIN_TOKEN:?CHAOS_ADMIN_TOKEN must be set (the demo-api chaos token)}"

echo ">> recovering: clearing all chaos (error_rate=0 latency_ms=0 outage=false)"
exec python3 "${SCRIPT_DIR}/chaos.py" off "$@"
