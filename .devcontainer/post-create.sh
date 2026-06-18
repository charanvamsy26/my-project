#!/usr/bin/env bash
# =============================================================================
# postCreate for the eks-gitops-platform local-demo dev container.
#
# Runs once after the container is built. It deliberately does NOT boot the
# cluster (that is heavy and a user may just want to read the code) — instead it
# verifies the toolchain installed by the devcontainer features and prints clear
# guidance to run `make demo-up`.
#
# Toolchain expected (provided by .devcontainer/devcontainer.json features):
#   docker (docker-in-docker), kind, kubectl, helm.
# =============================================================================
set -euo pipefail

echo
echo "==> eks-gitops-platform local demo — toolchain check"
missing=0
for t in docker kind kubectl helm; do
  if command -v "$t" >/dev/null 2>&1; then
    ver="$("$t" version --client 2>/dev/null | head -n1 || "$t" --version 2>/dev/null | head -n1 || true)"
    printf '  ok      %-8s %s\n' "$t" "$ver"
  else
    printf '  MISSING %-8s (expected from a devcontainer feature)\n' "$t"
    missing=1
  fi
done

echo
echo "==> Next step: bring the demo up on a local kind cluster (NO AWS):"
echo
echo "      make demo-up"
echo
echo "   Then port-forward and open the UIs (these ports are auto-forwarded):"
echo "      demo-api    -> http://localhost:8000   (kubectl -n demo port-forward svc/demo-api 8000:8000)"
echo "      Grafana     -> http://localhost:3000   (admin / admin, local-only credential)"
echo "      Prometheus  -> http://localhost:9090"
echo
echo "   Tear it down with:  make demo-down"
echo "   Details: .devcontainer/README.md and local/README.md"
echo

if [ "$missing" -ne 0 ]; then
  echo "WARNING: one or more tools are missing; rebuild the dev container to reinstall features." >&2
fi

# Never fail container creation just because a tool check was noisy.
exit 0
