# syntax=docker/dockerfile:1.7
#
# Multi-stage build for demo-api.
#   stage 1 (builder): install Python deps into an isolated prefix.
#   stage 2 (runtime): copy only the installed packages + app onto a slim base.
#
# Result: a small image with no build toolchain, running as a non-root user,
# serving gunicorn on :8000. Image is published as
# ghcr.io/charanvamsy/demo-api:<tag> (never :latest in deployments).

# --------------------------------------------------------------------------- #
# Stage 1 — builder
# --------------------------------------------------------------------------- #
FROM python:3.12-slim AS builder

# Don't write .pyc files or buffer stdout/stderr during the build.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

# Build deps for psycopg2-binary are bundled in the wheel, so we avoid apt here
# to keep the builder lean. If you switch to source psycopg2, add libpq-dev/gcc.
COPY requirements.txt .

# Install into a relocatable prefix we copy wholesale into the runtime image.
RUN python -m pip install --upgrade pip \
    && pip install --prefix=/install --no-cache-dir -r requirements.txt

# --------------------------------------------------------------------------- #
# Stage 2 — runtime
# --------------------------------------------------------------------------- #
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000 \
    APP_NAME=demo-api

# Create an unprivileged user/group up front. Running as non-root is enforced
# again at the Kubernetes layer (securityContext), defense in depth.
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --home-dir /app --no-create-home app

WORKDIR /app

# Copy the pre-built site-packages and console scripts (gunicorn) from builder.
COPY --from=builder /install /usr/local

# Copy application source. Only what we need at runtime (see .dockerignore).
COPY --chown=app:app src/ /app/src/

# Drop privileges. The runtime filesystem is also mounted read-only in k8s.
USER app

EXPOSE 8000

# Container-level healthcheck mirrors the Kubernetes liveness probe so the image
# is also usable/observable outside k8s (docker, compose, local).
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys; \
sys.exit(0) if urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2).status==200 else sys.exit(1)"

# Gunicorn config:
#   --workers 2: small footprint; HPA scales pods horizontally, not workers.
#   --threads 4: handle some concurrency per worker for I/O-bound DB probes.
#   --timeout 30 / --graceful-timeout 30: bound request + shutdown time.
#   --access-logfile -: stream access logs to stdout for the log pipeline.
WORKDIR /app/src
CMD ["gunicorn", "--bind", "0.0.0.0:8000", \
     "--workers", "2", "--threads", "4", \
     "--timeout", "30", "--graceful-timeout", "30", \
     "--access-logfile", "-", "--error-logfile", "-", \
     "app:app"]
