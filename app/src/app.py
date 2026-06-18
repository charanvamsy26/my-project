"""demo-api: a small, production-shaped Flask service.

This service exists to exercise the full platform stack (EKS + ALB Ingress +
Prometheus Operator + ArgoCD + Gatekeeper). It is intentionally small but
behaves like a real service: structured JSON logs, Prometheus metrics, distinct
liveness/readiness semantics, and graceful degradation when its (optional)
database is unavailable.

Design notes
------------
* Liveness (/healthz) must answer cheaply and never depend on downstream
  systems. If it fails, Kubernetes restarts the pod -- so it only reports that
  the process itself is up.
* Readiness (/readyz) reflects whether we can serve traffic. When a
  DATABASE_URL is configured we probe it; if the probe fails we report NOT ready
  (503) so the Service/ALB stops sending us traffic, but we do NOT crash. When
  no DATABASE_URL is set, the service is "stateless" and always ready. A chaos
  "outage" toggle can also force /readyz to 503 on demand (see below).
* Metrics (/metrics) are exposed via prometheus_client and scraped by the
  Prometheus Operator (see the chart's ServiceMonitor).

Metrics contract (source of truth: observability/prometheus/rules/*.yaml and
observability/grafana/dashboards/demo-api-overview.json)
-----------------------------------------------------------------------------
The Prometheus recording/alert/SLO rules and the Grafana dashboard are the
canonical contract; this app conforms to THEM. They query:

    http_requests_total{service,path,status}            (Counter)
    http_request_duration_seconds_bucket{service,path,status,le}  (Histogram)

with service="demo-api" and `status` as the RAW numeric HTTP code (the rules
match it with status=~"5.." / status="2xx-no"), e.g. "200", "404", "500", "503".
The `path` label carries the matched route TEMPLATE (e.g. "/", "/healthz") so
cardinality stays bounded. The `namespace` label seen in the rules' `sum by`
clauses is injected by Prometheus at scrape time from the Kubernetes target —
the app must NOT emit it.

Fault injection (chaos)
-----------------------
Safe-by-default hooks let the chaos layer burn the error budget on demand:
  * CHAOS_ERROR_RATE   float 0.0-1.0  -> fraction of "/" requests that 500.
  * CHAOS_LATENCY_MS   int >= 0       -> extra latency added to "/" requests.
  * CHAOS_OUTAGE       "true"         -> /readyz returns 503 (pod NotReady).
  * CHAOS_ADMIN_TOKEN  secret         -> if set, enables GET/POST /admin/chaos
                                         (guarded by this shared token). If
                                         unset, the admin endpoint is disabled.
Injected errors and latency are still recorded in the metrics, so the burn
shows up on the dashboards/alerts.
"""

from __future__ import annotations

import logging
import os
import random
import sys
import threading
import time
from typing import Optional

from flask import Flask, Response, g, jsonify, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Histogram,
    generate_latest,
)

# psycopg2 is optional at runtime: the service is fully functional without a DB.
# Importing lazily/defensively keeps local dev and DB-less deploys simple.
try:  # pragma: no cover - import guard
    import psycopg2  # type: ignore
except Exception:  # pragma: no cover - psycopg2 not installed / unavailable
    psycopg2 = None  # type: ignore


# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #
APP_NAME = os.environ.get("APP_NAME", "demo-api")
APP_VERSION = os.environ.get("APP_VERSION", "0.1.0")
# Optional Postgres DSN. When unset, the service runs in stateless mode.
DATABASE_URL: Optional[str] = os.environ.get("DATABASE_URL") or None
# Readiness DB probe timeout (seconds). Kept short so /readyz stays snappy.
DB_CONNECT_TIMEOUT = int(os.environ.get("DB_CONNECT_TIMEOUT", "2"))

# The constant `service` label value every metric series carries. This MUST
# match the value the Prometheus rules and Grafana dashboard select on
# (service="demo-api"); changing it silently breaks every panel and alert.
SERVICE = APP_NAME

# Optional shared token guarding the runtime chaos admin endpoint. When unset
# (the default), /admin/chaos is disabled entirely.
CHAOS_ADMIN_TOKEN: Optional[str] = os.environ.get("CHAOS_ADMIN_TOKEN") or None


# --------------------------------------------------------------------------- #
# Structured logging
# --------------------------------------------------------------------------- #
class JsonLogFormatter(logging.Formatter):
    """Minimal structured JSON formatter.

    Why hand-rolled instead of a dependency: it keeps the image small and the
    output stable/parseable for Loki/CloudWatch without pulling extra libs.
    """

    def format(self, record: logging.LogRecord) -> str:
        import json

        payload = {
            "ts": self.formatTime(record, datefmt="%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
            "service": APP_NAME,
            "version": APP_VERSION,
        }
        # Attach request-scoped fields when present (set in before/after hooks).
        for key in ("method", "path", "status", "duration_ms", "remote_addr"):
            value = getattr(record, key, None)
            if value is not None:
                payload[key] = value
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, separators=(",", ":"))


def _configure_logging() -> logging.Logger:
    handler = logging.StreamHandler(stream=sys.stdout)
    handler.setFormatter(JsonLogFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())
    return logging.getLogger(APP_NAME)


log = _configure_logging()


# --------------------------------------------------------------------------- #
# Prometheus metrics — MUST match the rules/dashboard contract exactly.
# -----------------------------------------------------------------------------
# Counter:   http_requests_total{service,path,status}
# Histogram: http_request_duration_seconds{service,path,status}
#            -> exposes http_request_duration_seconds_bucket{...,le}
#
# `path` is the matched route TEMPLATE (e.g. "/", "/healthz") not the raw URL,
# so /items/123 and /items/456 collapse into one series. `status` is the RAW
# numeric HTTP code as a string ("200", "500", ...) because the rules match it
# with regexes like status=~"5.." (raw codes), not status classes ("5xx").
# `service` is a constant ("demo-api"). `namespace` is NOT emitted here; it is
# injected by Prometheus from the scrape target.
# --------------------------------------------------------------------------- #
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests processed by demo-api.",
    ["service", "path", "status"],
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ["service", "path", "status"],
    # Buckets tuned for a fast API (sub-second). The 0.5s bucket aligns with the
    # p99 latency SLO (DemoApiHighLatencyP99 fires above 500ms). Tail buckets
    # catch outliers (e.g. injected chaos latency).
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)


# --------------------------------------------------------------------------- #
# Chaos / fault-injection state
# -----------------------------------------------------------------------------
# Safe-by-default and overridable at runtime via /admin/chaos (when a token is
# configured). All knobs are guarded by a lock so the admin endpoint and the
# request path see a consistent snapshot.
# --------------------------------------------------------------------------- #
class ChaosState:
    """Mutable, thread-safe holder for the fault-injection knobs."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.error_rate: float = _env_float("CHAOS_ERROR_RATE", 0.0)
        self.latency_ms: int = _env_int("CHAOS_LATENCY_MS", 0)
        self.outage: bool = _env_bool("CHAOS_OUTAGE", False)

    def snapshot(self) -> dict:
        with self._lock:
            return {
                "error_rate": self.error_rate,
                "latency_ms": self.latency_ms,
                "outage": self.outage,
            }

    def update(
        self,
        *,
        error_rate: Optional[float] = None,
        latency_ms: Optional[int] = None,
        outage: Optional[bool] = None,
    ) -> dict:
        with self._lock:
            if error_rate is not None:
                self.error_rate = _clamp01(float(error_rate))
            if latency_ms is not None:
                self.latency_ms = max(0, int(latency_ms))
            if outage is not None:
                self.outage = bool(outage)
            return {
                "error_rate": self.error_rate,
                "latency_ms": self.latency_ms,
                "outage": self.outage,
            }


def _clamp01(value: float) -> float:
    return max(0.0, min(1.0, value))


def _env_float(name: str, default: float) -> float:
    try:
        return _clamp01(float(os.environ.get(name, default)))
    except (TypeError, ValueError):
        return default


def _env_int(name: str, default: int) -> int:
    try:
        return max(0, int(os.environ.get(name, default)))
    except (TypeError, ValueError):
        return default


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


chaos = ChaosState()


def create_app() -> Flask:
    app = Flask(APP_NAME)

    # ------------------------------------------------------------------ #
    # Request instrumentation + access logging
    # ------------------------------------------------------------------ #
    @app.before_request
    def _start_timer() -> None:
        g.start_time = time.perf_counter()

    def _record(path: str, status_code: int, elapsed: float) -> None:
        """Emit the canonical RED metrics for a single request.

        `status_code` is recorded as the raw numeric code (str) so it matches
        the rules' status=~"5.." regexes. Always called — including for chaos-
        injected errors/latency — so the error budget burn is visible.
        """
        status = str(status_code)
        REQUEST_COUNT.labels(SERVICE, path, status).inc()
        REQUEST_LATENCY.labels(SERVICE, path, status).observe(elapsed)

    @app.after_request
    def _record_metrics(response: Response) -> Response:
        # Skip the metrics endpoint itself to avoid self-referential noise.
        endpoint = request.endpoint or "unknown"
        if endpoint != "metrics":
            elapsed = time.perf_counter() - getattr(
                g, "start_time", time.perf_counter()
            )
            # Use the matched route rule for a stable, low-cardinality `path`.
            route = request.url_rule.rule if request.url_rule else request.path
            _record(route, response.status_code, elapsed)
            log.info(
                "request",
                extra={
                    "method": request.method,
                    "path": request.path,
                    "status": response.status_code,
                    "duration_ms": round(elapsed * 1000, 2),
                    "remote_addr": request.remote_addr,
                },
            )
        return response

    # ------------------------------------------------------------------ #
    # Routes
    # ------------------------------------------------------------------ #
    @app.get("/")
    def hello() -> Response:
        # Chaos hooks live on "/" so load tests against the root path can be
        # made to burn the error budget on demand. Injected latency and errors
        # both flow through the normal after_request path, so they are counted.
        state = chaos.snapshot()

        if state["latency_ms"] > 0:
            time.sleep(state["latency_ms"] / 1000.0)

        if state["error_rate"] > 0 and random.random() < state["error_rate"]:
            log.warning("chaos: injecting 500", extra={"path": "/"})
            return jsonify({"error": "chaos-injected failure"}), 500

        return jsonify(
            {
                "service": APP_NAME,
                "version": APP_VERSION,
                "message": "Hello from demo-api",
                "stateful": DATABASE_URL is not None,
            }
        )

    @app.get("/healthz")
    def healthz() -> Response:
        # Liveness: only the process matters. Never touch the DB or chaos here,
        # or a transient blip / chaos outage would trigger pointless restarts.
        return jsonify({"status": "ok"})

    @app.get("/readyz")
    def readyz() -> Response:
        # Chaos outage forces NotReady so the pod is drained from rotation
        # without crashing (liveness still passes, so it is not restarted).
        if chaos.snapshot()["outage"]:
            log.warning("chaos: forcing readiness outage", extra={"path": "/readyz"})
            return jsonify({"status": "not-ready", "reason": "chaos-outage"}), 503

        # Readiness: are we able to serve? In stateless mode, always yes.
        if DATABASE_URL is None:
            return jsonify({"status": "ready", "database": "disabled"})

        ok, detail = _check_database()
        if ok:
            return jsonify({"status": "ready", "database": "ok"})
        # 503 -> removed from endpoints; pod stays alive and retries.
        log.warning("readiness probe failed", extra={"path": "/readyz"})
        return (
            jsonify({"status": "not-ready", "database": detail}),
            503,
        )

    @app.get("/metrics")
    def metrics() -> Response:
        return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)

    # ------------------------------------------------------------------ #
    # Chaos admin — guarded runtime toggle. Disabled unless a token is set.
    # ------------------------------------------------------------------ #
    @app.get("/admin/chaos")
    def get_chaos() -> Response:
        denied = _check_chaos_auth()
        if denied is not None:
            return denied
        return jsonify(chaos.snapshot())

    @app.post("/admin/chaos")
    def set_chaos() -> Response:
        denied = _check_chaos_auth()
        if denied is not None:
            return denied

        body = request.get_json(silent=True) or {}
        try:
            new_state = chaos.update(
                error_rate=body.get("error_rate"),
                latency_ms=body.get("latency_ms"),
                outage=body.get("outage"),
            )
        except (TypeError, ValueError):
            return jsonify({"error": "invalid chaos parameters"}), 400

        log.warning("chaos: state updated via admin", extra={"path": "/admin/chaos"})
        return jsonify(new_state)

    @app.errorhandler(404)
    def not_found(_err) -> Response:
        return jsonify({"error": "not found"}), 404

    @app.errorhandler(Exception)
    def internal_error(err: Exception):  # pragma: no cover - safety net
        log.exception("unhandled exception")
        return jsonify({"error": "internal server error"}), 500

    return app


def _check_chaos_auth() -> Optional[tuple]:
    """Authorize a chaos-admin request.

    Returns None when the request is allowed, or a Flask (body, status) tuple to
    short-circuit with. If no token is configured the endpoint is disabled (404)
    so it is never exposed by accident; with a token, callers must present it in
    the X-Chaos-Token header (or Authorization: Bearer <token>).
    """
    if CHAOS_ADMIN_TOKEN is None:
        # Endpoint disabled: behave as if the route does not exist.
        return (jsonify({"error": "not found"}), 404)

    presented = request.headers.get("X-Chaos-Token")
    if presented is None:
        auth = request.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            presented = auth[len("Bearer ") :]

    if presented != CHAOS_ADMIN_TOKEN:
        return (jsonify({"error": "unauthorized"}), 401)

    return None


def _check_database() -> tuple[bool, str]:
    """Probe the configured database. Returns (ok, detail).

    Failures are reported, never raised, so /readyz can degrade gracefully.
    """
    if psycopg2 is None:
        return False, "psycopg2-not-installed"
    if not DATABASE_URL:
        return True, "disabled"
    conn = None
    try:
        conn = psycopg2.connect(DATABASE_URL, connect_timeout=DB_CONNECT_TIMEOUT)
        with conn.cursor() as cur:
            cur.execute("SELECT 1;")
            cur.fetchone()
        return True, "ok"
    except Exception as exc:  # noqa: BLE001 - we deliberately swallow & report
        return False, f"error: {exc.__class__.__name__}"
    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:  # pragma: no cover
                pass


# Module-level app for gunicorn: `gunicorn 'app:app'`
app = create_app()


if __name__ == "__main__":
    # Local dev only. In containers we run gunicorn (see Dockerfile).
    port = int(os.environ.get("PORT", "8000"))
    app.run(host="0.0.0.0", port=port)  # noqa: S104 - intended for dev/container
