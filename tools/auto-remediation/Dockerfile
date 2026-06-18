# =============================================================================
# auto-remediation controller image — multi-stage, non-root, pinned base.
# -----------------------------------------------------------------------------
# Stage 1 (builder): install Python deps into a throwaway layer with build tools.
# Stage 2 (runtime): copy ONLY the installed site-packages + app onto a slim,
#                    digest-pinned base, run as an unprivileged user.
#
# Complies with the platform Gatekeeper constraints when deployed:
#   * image from ghcr.io/charanvamsy26/... with an explicit, non-:latest tag
#   * runs as non-root (USER 10001); the manifest also drops ALL caps +
#     readOnlyRootFilesystem (this image writes nothing outside /tmp).
#
# Build/push (CI does this; tag with the git SHA, never :latest):
#   docker build -t ghcr.io/charanvamsy26/auto-remediation:0.1.0 .
#   docker push  ghcr.io/charanvamsy26/auto-remediation:0.1.0
# =============================================================================

# Pin the base by tag AND digest so rebuilds are reproducible and supply-chain
# safe. The digest below is a documented placeholder — replace it with the digest
# your CI resolves for python:3.12-slim-bookworm (docker buildx imagetools
# inspect python:3.12-slim-bookworm) before publishing.
ARG PYTHON_BASE=python:3.12-slim-bookworm@sha256:0000000000000000000000000000000000000000000000000000000000000000

# -----------------------------------------------------------------------------
# Stage 1: builder
# -----------------------------------------------------------------------------
FROM ${PYTHON_BASE} AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /build

# Install dependencies into an isolated prefix we can copy wholesale into runtime.
COPY requirements.txt .
RUN pip install --prefix=/install -r requirements.txt

# -----------------------------------------------------------------------------
# Stage 2: runtime
# -----------------------------------------------------------------------------
FROM ${PYTHON_BASE} AS runtime

# OCI labels for provenance.
LABEL org.opencontainers.image.title="auto-remediation" \
      org.opencontainers.image.description="Self-healing controller for demo-api SLO burn" \
      org.opencontainers.image.source="https://github.com/charanvamsy26/my-project" \
      org.opencontainers.image.licenses="MIT"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    # Default to the safe posture; the Deployment overrides these explicitly.
    DRY_RUN=true \
    MODE=restart \
    PATH=/usr/local/bin:$PATH

# Copy the installed Python packages from the builder. No build tools land here.
COPY --from=builder /install /usr/local

WORKDIR /app
COPY remediator.py /app/remediator.py

# Create an unprivileged user/group (uid:gid 10001) to match the pod
# securityContext (runAsNonRoot/runAsUser: 10001). Owns nothing writable; the
# app needs no write access to the image filesystem.
RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app
USER 10001:10001

# No ports exposed: this is a controller, not a server (no inbound traffic).
ENTRYPOINT ["python", "/app/remediator.py"]
