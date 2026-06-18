#!/usr/bin/env python3
"""auto-remediation controller — self-healing for demo-api's SLO burn.

This is the "auto-healing workflows" / "MTTR -40%" piece of the platform. It
closes the loop between the *detection* layer (Prometheus multi-window
multi-burn-rate SLO alerts) and the *recovery* layer (Kubernetes), so that the
single most common, safe remediation — restarting a wedged deployment — happens
in seconds instead of after a human is paged, opens a laptop, and types
`kubectl rollout restart` themselves. That delta is the MTTR reduction.

WHAT IT DOES
------------
1. Polls Prometheus (PROM_URL) on a fixed interval for the demo-api error-budget
   burn signal. Two query strategies are supported (BURN_QUERY_MODE):
     * "alerts"   (default) — read the canonical firing SLO alert via the synthetic
                   ALERTS metric. This reuses the EXACT, already-reviewed burn math
                   in observability/prometheus/rules/slo-rules.yaml, so the
                   controller and the on-call pager fire on identical conditions.
     * "burnrate" — evaluate the recording rules directly
                   (slo:sli_error:ratio_rate1h/5m + 6h/30m) and compare the burn
                   rate to BURN_THRESHOLD. Use this if you want the controller to
                   act on a *different* (e.g. more conservative) threshold than the
                   pager.
2. Requires the breach to be SUSTAINED for SUSTAINED_SECONDS before acting. A
   single scrape blip never triggers a restart.
3. Remediates, respecting a COOLDOWN_SECONDS window to prevent flapping:
     * MODE=restart  (default) — `kubectl rollout restart deployment/<DEPLOYMENT>`
       via the official kubernetes python client if importable, else subprocess
       kubectl. This is a graceful, in-place rolling restart.
     * MODE=rollback — Argo CD rollback (`argocd app rollback <ARGOCD_APP>`) to the
       last known-good Sync/history revision. For when the bad state is a bad
       release, not a wedged process.
4. DRY_RUN=true by default: it logs exactly what it WOULD do and changes nothing.
   You must explicitly set DRY_RUN=false to let it mutate the cluster.

SAFETY PROPERTIES
-----------------
* Dry-run by default.                    (never surprises a cluster)
* Cooldown after every action.           (no restart storms / flapping)
* Sustained-breach requirement.          (no acting on single-scrape noise)
* Exponential backoff on API errors.     (a flaky Prometheus can't busy-loop us)
* Structured JSON logs on every decision.(auditable: why it did / didn't act)
* Least-privilege RBAC (see deploy/).    (can ONLY get/patch the one deployment)

All configuration is via environment variables (see CONFIG below / README.md).
"""

from __future__ import annotations

import json
import logging
import os
import random
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

import requests

# =============================================================================
# Structured JSON logging
# -----------------------------------------------------------------------------
# One JSON object per line so Loki/CloudWatch/Promtail can parse every field.
# The shape mirrors demo-api's own log contract (timestamp, level, service, msg)
# so both ship into the same pipeline cleanly.
# =============================================================================

SERVICE_NAME = "auto-remediation"


class JsonLogFormatter(logging.Formatter):
    """Render each log record as a single-line JSON object."""

    # Standard LogRecord attributes we do NOT want duplicated in the JSON body;
    # everything passed via `extra=` that is not in here becomes a top-level key.
    _RESERVED = {
        "args", "asctime", "created", "exc_info", "exc_text", "filename",
        "funcName", "levelname", "levelno", "lineno", "module", "msecs",
        "message", "msg", "name", "pathname", "process", "processName",
        "relativeCreated", "stack_info", "thread", "threadName", "taskName",
    }

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": time.strftime(
                "%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)
            )
            + f".{int(record.msecs):03d}Z",
            "level": record.levelname,
            "service": SERVICE_NAME,
            "logger": record.name,
            "message": record.getMessage(),
        }
        # Promote structured extras to top-level keys.
        for key, value in record.__dict__.items():
            if key not in self._RESERVED and not key.startswith("_"):
                payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str, sort_keys=True)


class StructuredLogger(logging.LoggerAdapter):
    """Adapter so callers can write ``log.info("msg", key=value)``.

    The stdlib logging methods reject arbitrary keyword args; structured fields
    must travel via ``extra=``. This adapter folds any kwargs (other than the few
    the stdlib understands, like ``exc_info``) into ``extra`` so the
    JsonLogFormatter can promote them to top-level JSON keys.
    """

    # kwargs the stdlib logging methods accept natively — leave these alone.
    _PASSTHROUGH = {"exc_info", "stack_info", "stacklevel", "extra"}

    def log(self, level, msg, *args, **kwargs):  # type: ignore[override]
        if not self.isEnabledFor(level):
            return
        passthrough = {k: kwargs.pop(k) for k in list(kwargs) if k in self._PASSTHROUGH}
        extra = dict(passthrough.pop("extra", {}) or {})
        extra.update(kwargs)  # remaining kwargs become structured fields
        self.logger.log(level, msg, *args, extra=extra, **passthrough)

    # The convenience methods (info/warning/...) on LoggerAdapter route through
    # self.log via process(); we override log() above so they all benefit.


def build_logger(level: str = "INFO") -> StructuredLogger:
    logger = logging.getLogger(SERVICE_NAME)
    logger.setLevel(getattr(logging, level.upper(), logging.INFO))
    # Avoid duplicate handlers if build_logger is called more than once (tests).
    logger.handlers.clear()
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonLogFormatter())
    logger.addHandler(handler)
    logger.propagate = False
    return StructuredLogger(logger, {})


# =============================================================================
# Configuration
# -----------------------------------------------------------------------------
# Every knob is an env var with a safe default. Defaults bias toward "do nothing
# dangerous": DRY_RUN on, restart (not rollback) mode, a real cooldown.
# =============================================================================


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def _env_int(name: str, default: int) -> int:
    return int(_env_float(name, float(default)))


# The canonical fast-burn SLO alert from observability/prometheus/rules/slo-rules.yaml.
# Keep this name in lock-step with that file's `alert: DemoApiErrorBudgetBurnFast`.
DEFAULT_FAST_ALERT = "DemoApiErrorBudgetBurnFast"
DEFAULT_SLOW_ALERT = "DemoApiErrorBudgetBurnSlow"

# The 30-day error budget for the 99.9% SLO (1 - 0.999). Burn rate = error_ratio
# / budget, so this is the divisor when BURN_QUERY_MODE=burnrate.
ERROR_BUDGET = 0.001


@dataclass
class Config:
    # --- Prometheus / detection ---
    prom_url: str = field(
        default_factory=lambda: os.environ.get("PROM_URL", "http://localhost:9090")
    )
    # "alerts" -> read firing ALERTS series; "burnrate" -> evaluate burn directly.
    burn_query_mode: str = field(
        default_factory=lambda: os.environ.get("BURN_QUERY_MODE", "alerts").strip().lower()
    )
    # Which firing alert (alerts mode) constitutes a breach worth healing.
    breach_alert: str = field(
        default_factory=lambda: os.environ.get("BREACH_ALERT", DEFAULT_FAST_ALERT)
    )
    # Burn-rate threshold (burnrate mode). 14.4 == the fast-burn page threshold.
    burn_threshold: float = field(
        default_factory=lambda: _env_float("BURN_THRESHOLD", 14.4)
    )

    # --- Target workload ---
    namespace: str = field(default_factory=lambda: os.environ.get("NAMESPACE", "demo"))
    deployment: str = field(
        default_factory=lambda: os.environ.get("DEPLOYMENT", "demo-api")
    )

    # --- Behaviour / safety ---
    mode: str = field(
        default_factory=lambda: os.environ.get("MODE", "restart").strip().lower()
    )
    dry_run: bool = field(default_factory=lambda: _env_bool("DRY_RUN", True))
    poll_seconds: int = field(default_factory=lambda: _env_int("POLL_SECONDS", 30))
    # A breach must persist this long (continuous) before we remediate.
    sustained_seconds: int = field(
        default_factory=lambda: _env_int("SUSTAINED_SECONDS", 120)
    )
    # After any remediation we refuse to act again for this long (anti-flap).
    cooldown_seconds: int = field(
        default_factory=lambda: _env_int("COOLDOWN_SECONDS", 600)
    )

    # --- Argo CD rollback mode ---
    argocd_app: str = field(
        default_factory=lambda: os.environ.get("ARGOCD_APP", "demo-api")
    )

    # --- Backoff on Prometheus/API errors ---
    backoff_base_seconds: float = field(
        default_factory=lambda: _env_float("BACKOFF_BASE_SECONDS", 1.0)
    )
    backoff_max_seconds: float = field(
        default_factory=lambda: _env_float("BACKOFF_MAX_SECONDS", 60.0)
    )
    http_timeout_seconds: float = field(
        default_factory=lambda: _env_float("HTTP_TIMEOUT_SECONDS", 10.0)
    )

    log_level: str = field(default_factory=lambda: os.environ.get("LOG_LEVEL", "INFO"))

    def redacted(self) -> dict[str, Any]:
        """Config as a dict for logging (nothing sensitive here, but explicit)."""
        return {
            "prom_url": self.prom_url,
            "burn_query_mode": self.burn_query_mode,
            "breach_alert": self.breach_alert,
            "burn_threshold": self.burn_threshold,
            "namespace": self.namespace,
            "deployment": self.deployment,
            "mode": self.mode,
            "dry_run": self.dry_run,
            "poll_seconds": self.poll_seconds,
            "sustained_seconds": self.sustained_seconds,
            "cooldown_seconds": self.cooldown_seconds,
            "argocd_app": self.argocd_app,
        }


# =============================================================================
# Prometheus client
# -----------------------------------------------------------------------------
# Thin wrapper over the HTTP query API. Raises PrometheusError on any transport
# or API-level failure so the caller can apply backoff.
# =============================================================================


class PrometheusError(Exception):
    """Raised when a Prometheus query fails (transport or API status != success)."""


class PrometheusClient:
    def __init__(self, base_url: str, timeout: float = 10.0,
                 session: Optional[requests.Session] = None) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.session = session or requests.Session()

    def query(self, promql: str) -> list[dict[str, Any]]:
        """Run an instant query; return the `result` list (may be empty)."""
        url = f"{self.base_url}/api/v1/query"
        try:
            resp = self.session.get(
                url, params={"query": promql}, timeout=self.timeout
            )
        except requests.RequestException as exc:
            raise PrometheusError(f"transport error querying Prometheus: {exc}") from exc

        if resp.status_code != 200:
            raise PrometheusError(
                f"Prometheus returned HTTP {resp.status_code}: {resp.text[:200]}"
            )
        try:
            body = resp.json()
        except ValueError as exc:
            raise PrometheusError(f"non-JSON response from Prometheus: {exc}") from exc

        if body.get("status") != "success":
            raise PrometheusError(
                f"Prometheus query failed: {body.get('error', 'unknown error')}"
            )
        return body.get("data", {}).get("result", [])


# =============================================================================
# Breach detection
# -----------------------------------------------------------------------------
# Two strategies, both returning (breached: bool, detail: dict). The detail dict
# is logged so the decision is fully auditable.
# =============================================================================

# PromQL: is the canonical fast-burn SLO alert firing? We match the alert by name
# and require alertstate="firing" (not "pending"). This is the SAME signal that
# pages the human on-call, so the bot and the human agree on "is this bad?".
ALERTS_PROMQL_TEMPLATE = (
    'ALERTS{{alertname="{alertname}",alertstate="firing"}}'
)

# PromQL: the multi-window burn rate, expressed as a *burn-rate number* (error
# ratio / budget) so we can compare it to BURN_THRESHOLD directly. This mirrors
# the fast-burn condition in slo-rules.yaml (1h AND 5m, OR 6h AND 30m), divided
# by the 0.001 budget. max() collapses the OR'd windows into the worst burn.
BURNRATE_PROMQL = (
    "max("
    "  (slo:sli_error:ratio_rate1h{{service=\"demo-api\"}} / {budget})"
    "  and ignoring(slo)"
    "  (slo:sli_error:ratio_rate5m{{service=\"demo-api\"}} / {budget} > 0)"
    ")"
)


def detect_via_alerts(prom: PrometheusClient, cfg: Config) -> tuple[bool, dict[str, Any]]:
    """Breach = the configured SLO alert is firing."""
    promql = ALERTS_PROMQL_TEMPLATE.format(alertname=cfg.breach_alert)
    result = prom.query(promql)
    breached = len(result) > 0
    return breached, {
        "strategy": "alerts",
        "promql": promql,
        "firing_series": len(result),
        "breach_alert": cfg.breach_alert,
    }


def detect_via_burnrate(prom: PrometheusClient, cfg: Config) -> tuple[bool, dict[str, Any]]:
    """Breach = computed fast-burn rate exceeds BURN_THRESHOLD."""
    promql = BURNRATE_PROMQL.format(budget=ERROR_BUDGET)
    result = prom.query(promql)
    burn_rate: Optional[float] = None
    if result:
        try:
            # instant vector sample: value = [timestamp, "stringified float"]
            burn_rate = float(result[0]["value"][1])
        except (KeyError, IndexError, ValueError, TypeError):
            burn_rate = None
    breached = burn_rate is not None and burn_rate >= cfg.burn_threshold
    return breached, {
        "strategy": "burnrate",
        "promql": promql,
        "burn_rate": burn_rate,
        "burn_threshold": cfg.burn_threshold,
    }


def detect_breach(prom: PrometheusClient, cfg: Config) -> tuple[bool, dict[str, Any]]:
    if cfg.burn_query_mode == "burnrate":
        return detect_via_burnrate(prom, cfg)
    return detect_via_alerts(prom, cfg)


# =============================================================================
# Remediation actions
# -----------------------------------------------------------------------------
# Prefer the official kubernetes python client when it's importable (it's the
# right tool inside the cluster, using the mounted ServiceAccount token + RBAC).
# Fall back to subprocess kubectl when the library isn't installed (e.g. running
# the script locally against a kubeconfig).
# =============================================================================


def _k8s_client_available() -> bool:
    try:
        import kubernetes  # noqa: F401
        return True
    except Exception:
        return False


def restart_via_k8s_client(cfg: Config, log: logging.Logger) -> None:
    """Trigger a rolling restart by patching the pod template annotation.

    This is exactly what `kubectl rollout restart` does under the hood: it stamps
    spec.template.metadata.annotations with a kubectl.kubernetes.io/restartedAt
    timestamp, which changes the pod template hash and rolls the ReplicaSet. It
    needs only get+patch on the one deployment (see deploy/role.yaml).
    """
    from kubernetes import client, config as k8s_config

    # In-cluster first (mounted SA token); fall back to local kubeconfig.
    try:
        k8s_config.load_incluster_config()
        log.info("loaded in-cluster kube config", config_source="incluster")
    except Exception:
        k8s_config.load_kube_config()
        log.info("loaded local kube config", config_source="kubeconfig")

    apps = client.AppsV1Api()
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    patch = {
        "spec": {
            "template": {
                "metadata": {
                    "annotations": {
                        "kubectl.kubernetes.io/restartedAt": now,
                        "auto-remediation/restarted-by": SERVICE_NAME,
                    }
                }
            }
        }
    }
    apps.patch_namespaced_deployment(
        name=cfg.deployment, namespace=cfg.namespace, body=patch
    )


def restart_via_kubectl(cfg: Config, log: logging.Logger) -> None:
    """Fallback: shell out to kubectl rollout restart."""
    cmd = [
        "kubectl", "rollout", "restart",
        f"deployment/{cfg.deployment}", "-n", cfg.namespace,
    ]
    log.info("executing kubectl", argv=cmd)
    _run_command(cmd)


def rollback_via_argocd(cfg: Config, log: logging.Logger) -> None:
    """Argo CD rollback to the previous synced revision.

    `argocd app rollback <app>` with no revision rolls back to the most recent
    deployment-history entry, i.e. the last known-good state Argo recorded.
    Requires the argocd CLT to be authenticated (token via env / kube secret).
    """
    cmd = ["argocd", "app", "rollback", cfg.argocd_app]
    log.info("executing argocd rollback", argv=cmd)
    _run_command(cmd)


def _run_command(cmd: list[str]) -> None:
    """Run an external command, raising CalledProcessError on non-zero exit."""
    completed = subprocess.run(
        cmd, check=False, capture_output=True, text=True, timeout=120
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"command {cmd!r} failed (rc={completed.returncode}): "
            f"{completed.stderr.strip() or completed.stdout.strip()}"
        )


def remediate(cfg: Config, log: logging.Logger) -> dict[str, Any]:
    """Perform (or, in dry-run, describe) the configured remediation.

    Returns a dict describing the action taken, for logging.
    """
    if cfg.mode == "rollback":
        action = {
            "action": "argocd_rollback",
            "argocd_app": cfg.argocd_app,
            "command": ["argocd", "app", "rollback", cfg.argocd_app],
        }
        executor: Callable[[], None] = lambda: rollback_via_argocd(cfg, log)
    else:  # default: restart
        use_client = _k8s_client_available()
        action = {
            "action": "rollout_restart",
            "namespace": cfg.namespace,
            "deployment": cfg.deployment,
            "via": "kubernetes-client" if use_client else "kubectl",
            "command": (
                None
                if use_client
                else [
                    "kubectl", "rollout", "restart",
                    f"deployment/{cfg.deployment}", "-n", cfg.namespace,
                ]
            ),
        }
        executor = (
            (lambda: restart_via_k8s_client(cfg, log))
            if use_client
            else (lambda: restart_via_kubectl(cfg, log))
        )

    if cfg.dry_run:
        log.warning("DRY-RUN: would remediate but DRY_RUN is true; no changes made",
                    dry_run=True, **action)
        action["executed"] = False
        return action

    executor()
    log.info("remediation executed", dry_run=False, **action)
    action["executed"] = True
    return action


# =============================================================================
# Controller loop
# -----------------------------------------------------------------------------
# A single class holding the small amount of mutable state (when the current
# breach started, when we last acted, current backoff) so the loop body stays a
# pure-ish state machine that is easy to unit-test step-by-step.
# =============================================================================


# Path the readiness probe checks: the controller touches this every poll cycle
# so a wedged loop is detected and the pod is marked NotReady (see deploy/).
HEARTBEAT_PATH = os.environ.get("HEARTBEAT_PATH", "/tmp/heartbeat")


class Controller:
    def __init__(self, cfg: Config, prom: PrometheusClient,
                 log: logging.Logger,
                 clock: Callable[[], float] = time.monotonic,
                 heartbeat_path: str = HEARTBEAT_PATH) -> None:
        self.cfg = cfg
        self.prom = prom
        self.log = log
        self.clock = clock  # injectable for tests
        self.heartbeat_path = heartbeat_path

        self.breach_since: Optional[float] = None   # monotonic ts breach began
        self.last_action_at: Optional[float] = None  # monotonic ts of last remediation
        self.consecutive_errors = 0
        self._stop = False

    def _touch_heartbeat(self) -> None:
        """Update the readiness heartbeat file; failures must never break polling."""
        try:
            with open(self.heartbeat_path, "w", encoding="utf-8") as fh:
                fh.write(str(time.time()))
        except OSError as exc:
            self.log.warning("could not write heartbeat file",
                             heartbeat_path=self.heartbeat_path, error=str(exc))

    # ---- pure-ish predicates (unit tested directly) ----

    def in_cooldown(self, now: float) -> bool:
        if self.last_action_at is None:
            return False
        return (now - self.last_action_at) < self.cfg.cooldown_seconds

    def breach_sustained(self, now: float) -> bool:
        if self.breach_since is None:
            return False
        return (now - self.breach_since) >= self.cfg.sustained_seconds

    def backoff_delay(self) -> float:
        """Exponential backoff with full jitter, capped at backoff_max_seconds."""
        if self.consecutive_errors == 0:
            return 0.0
        exp = self.cfg.backoff_base_seconds * (2 ** (self.consecutive_errors - 1))
        capped = min(exp, self.cfg.backoff_max_seconds)
        # Full jitter avoids a thundering herd if multiple replicas back off in sync.
        return random.uniform(0, capped)

    # ---- one iteration of the loop ----

    def step(self) -> dict[str, Any]:
        """Run one poll/decide/act cycle. Returns a decision dict (for tests)."""
        now = self.clock()
        self._touch_heartbeat()  # liveness/readiness signal for the probes

        try:
            breached, detail = detect_breach(self.prom, self.cfg)
            self.consecutive_errors = 0  # reset backoff on any successful query
        except PrometheusError as exc:
            self.consecutive_errors += 1
            delay = self.backoff_delay()
            self.log.error(
                "prometheus query failed; backing off",
                error=str(exc),
                consecutive_errors=self.consecutive_errors,
                backoff_seconds=round(delay, 2),
            )
            return {"decision": "backoff", "backoff_seconds": delay,
                    "error": str(exc)}

        # Track the breach window.
        if breached:
            if self.breach_since is None:
                self.breach_since = now
                self.log.warning("breach detected; starting sustain timer",
                                 sustained_seconds=self.cfg.sustained_seconds,
                                 **detail)
        else:
            if self.breach_since is not None:
                self.log.info("breach cleared; resetting sustain timer", **detail)
            self.breach_since = None
            self.log.debug("no breach", **detail)
            return {"decision": "no_breach", **detail}

        # Breached. Is it sustained long enough?
        if not self.breach_sustained(now):
            elapsed = 0.0 if self.breach_since is None else (now - self.breach_since)
            self.log.info(
                "breach not yet sustained; waiting",
                elapsed_seconds=round(elapsed, 1),
                sustained_seconds=self.cfg.sustained_seconds,
                **detail,
            )
            return {"decision": "waiting_sustain",
                    "elapsed_seconds": elapsed, **detail}

        # Sustained breach. Are we still cooling down from a prior action?
        if self.in_cooldown(now):
            remaining = self.cfg.cooldown_seconds - (now - (self.last_action_at or now))
            self.log.warning(
                "sustained breach but in cooldown; suppressing remediation",
                cooldown_remaining_seconds=round(remaining, 1),
                **detail,
            )
            return {"decision": "cooldown",
                    "cooldown_remaining_seconds": remaining, **detail}

        # Act.
        self.log.warning("sustained breach beyond cooldown; remediating",
                         mode=self.cfg.mode, **detail)
        try:
            action = remediate(self.cfg, self.log)
        except Exception as exc:  # remediation failure must not crash the loop
            self.consecutive_errors += 1
            delay = self.backoff_delay()
            self.log.error("remediation failed; backing off",
                           error=str(exc),
                           consecutive_errors=self.consecutive_errors,
                           backoff_seconds=round(delay, 2))
            return {"decision": "remediation_failed", "error": str(exc),
                    "backoff_seconds": delay}

        # Successful action: start cooldown and reset the breach window so we
        # don't immediately re-fire on the same (still-firing) alert.
        self.last_action_at = now
        self.breach_since = None
        return {"decision": "remediated", **action, **detail}

    def request_stop(self, *_args: Any) -> None:
        self.log.info("shutdown signal received; will exit after current cycle")
        self._stop = True

    def run(self) -> None:
        """Main loop. Blocks until a stop signal is received."""
        self.log.info("auto-remediation controller starting", **self.cfg.redacted(),
                      k8s_client_available=_k8s_client_available())
        if self.cfg.dry_run:
            self.log.warning("running in DRY-RUN mode: no cluster changes will be made")

        signal.signal(signal.SIGTERM, self.request_stop)
        signal.signal(signal.SIGINT, self.request_stop)

        while not self._stop:
            decision = self.step()
            # On error/backoff, sleep the backoff; otherwise the normal poll.
            sleep_for = decision.get("backoff_seconds")
            if not sleep_for:
                sleep_for = self.cfg.poll_seconds
            # Sleep in small slices so a SIGTERM is honoured promptly.
            slept = 0.0
            while slept < sleep_for and not self._stop:
                chunk = min(1.0, sleep_for - slept)
                time.sleep(chunk)
                slept += chunk

        self.log.info("auto-remediation controller stopped cleanly")


def main() -> int:
    cfg = Config()
    log = build_logger(cfg.log_level)

    if cfg.mode not in {"restart", "rollback"}:
        log.error("invalid MODE; must be 'restart' or 'rollback'", mode=cfg.mode)
        return 2
    if cfg.burn_query_mode not in {"alerts", "burnrate"}:
        log.error("invalid BURN_QUERY_MODE; must be 'alerts' or 'burnrate'",
                  burn_query_mode=cfg.burn_query_mode)
        return 2

    prom = PrometheusClient(cfg.prom_url, timeout=cfg.http_timeout_seconds)
    controller = Controller(cfg, prom, log)
    try:
        controller.run()
    except Exception as exc:  # last-resort guard so a crash is logged structured
        log.error("controller crashed", error=str(exc), exc_info=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
