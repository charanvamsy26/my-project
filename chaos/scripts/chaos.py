#!/usr/bin/env python3
"""App-level chaos driver for demo-api (mechanism B).

Drives the demo-api guarded chaos endpoint (`/admin/chaos`) so the demo works on
a laptop / kind cluster with no Chaos Mesh, no privileges, and no cluster access
beyond reaching the service. Faults injected this way flow through the app's own
request instrumentation, so they DO burn the SLO error budget and light up the
dashboards/alerts (unlike Chaos Mesh HTTPChaos, which forges 5xx outside the app).

Chaos contract (matches app/src/app.py exactly):
  Endpoint : GET/POST {BASE_URL}/admin/chaos
  Auth     : header `X-Chaos-Token: <token>`  (or `Authorization: Bearer <token>`)
             token comes from env CHAOS_ADMIN_TOKEN; if the app has no token
             configured the endpoint returns 404 (disabled).
  Body     : JSON {"error_rate": 0.0-1.0, "latency_ms": >=0, "outage": bool}
             - error_rate : fraction of "/" requests that return 500 (clamped [0,1])
             - latency_ms : extra ms latency added to "/" requests (>= 0)
             - outage     : true -> /readyz returns 503 (pod NotReady; liveness stays up)
  GET returns the current chaos state; POST sets it and returns the new state.

Design:
  * stdlib only (urllib, json, argparse, os) — no pip install, matching the app's
    "chaos uses only stdlib" stance. Runs anywhere Python 3.8+ runs.
  * Idempotent: `off` (and `set` with any subset) just POSTs the desired state;
    re-running converges to the same place. Safe to run twice.
  * Safe by default: refuses to target an obviously-production URL unless you pass
    --i-know-what-im-doing. Never bakes a token into the file — it reads
    CHAOS_ADMIN_TOKEN from the environment.

Usage (BASE_URL via --url or env BASE_URL; token via env CHAOS_ADMIN_TOKEN):

  # Inspect current state.
  ./chaos.py status

  # Induce faults (each is a separate, composable knob):
  ./chaos.py errors --rate 0.5          # 50% of "/" requests 500
  ./chaos.py latency --ms 800           # +800ms on "/"
  ./chaos.py outage                     # /readyz -> 503 (NotReady)
  ./chaos.py set --rate 0.2 --ms 300    # set several knobs at once

  # Recover everything (idempotent — turns ALL chaos OFF):
  ./chaos.py off

Exit codes: 0 ok, 1 usage/precondition error, 2 HTTP/transport error.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any, Dict, Optional

DEFAULT_URL = "http://localhost:8000"
CHAOS_PATH = "/admin/chaos"
# Substrings that make us refuse to run unless explicitly overridden. Cheap guard
# against the #1 chaos foot-gun: pointing the driver at prod.
PROD_MARKERS = ("prod", "production")


# --------------------------------------------------------------------------- #
# HTTP helpers (stdlib only)
# --------------------------------------------------------------------------- #
def _endpoint(base_url: str) -> str:
    return base_url.rstrip("/") + CHAOS_PATH


def _request(method: str, base_url: str, token: str, body: Optional[Dict[str, Any]],
             timeout: float) -> Dict[str, Any]:
    """Call the chaos endpoint and return the parsed JSON state.

    Raises SystemExit with a clear message on auth/transport/HTTP errors so the
    CLI surfaces a single, readable failure instead of a traceback.
    """
    url = _endpoint(base_url)
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url=url, method=method, data=data)
    # Both header forms are accepted by the app; we send the explicit one.
    req.add_header("X-Chaos-Token", token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = resp.read().decode("utf-8")
            return json.loads(payload) if payload else {}
    except urllib.error.HTTPError as err:
        detail = err.read().decode("utf-8", "replace").strip()
        if err.code == 404:
            _die(2, f"{url} -> 404: chaos endpoint is DISABLED. The app only "
                    f"enables /admin/chaos when CHAOS_ADMIN_TOKEN is set in the "
                    f"demo-api pod's env. {detail}")
        if err.code == 401:
            _die(2, f"{url} -> 401 unauthorized: CHAOS_ADMIN_TOKEN does not match "
                    f"the token configured in the demo-api pod. {detail}")
        _die(2, f"{url} -> HTTP {err.code}: {detail}")
    except urllib.error.URLError as err:
        _die(2, f"cannot reach {url}: {err.reason}. Is demo-api running / "
                f"port-forwarded? (try: kubectl -n demo port-forward "
                f"svc/demo-api 8000:80 and BASE_URL=http://localhost:8000)")
    except json.JSONDecodeError as err:  # pragma: no cover - defensive
        _die(2, f"{url} returned non-JSON: {err}")
    return {}  # unreachable; keeps type checkers happy


def _die(code: int, msg: str) -> "None":
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def _print_state(label: str, state: Dict[str, Any]) -> None:
    print(f"{label}: {json.dumps(state, sort_keys=True)}")


# --------------------------------------------------------------------------- #
# Safety
# --------------------------------------------------------------------------- #
def _guard_prod(base_url: str, override: bool) -> None:
    lowered = base_url.lower()
    if any(marker in lowered for marker in PROD_MARKERS) and not override:
        _die(1, f"refusing to run against what looks like PRODUCTION ({base_url}). "
                f"Chaos must only target dev/staging. If you are certain, re-run "
                f"with --i-know-what-im-doing.")


def _resolve(args: argparse.Namespace) -> tuple[str, str]:
    base_url = args.url or os.environ.get("BASE_URL") or DEFAULT_URL
    token = os.environ.get("CHAOS_ADMIN_TOKEN", "")
    if not token:
        _die(1, "CHAOS_ADMIN_TOKEN is not set. Export the same token the demo-api "
                "pod was deployed with, e.g.  export CHAOS_ADMIN_TOKEN=... ")
    _guard_prod(base_url, args.force)
    return base_url, token


# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #
def cmd_status(args: argparse.Namespace) -> int:
    base_url, token = _resolve(args)
    state = _request("GET", base_url, token, None, args.timeout)
    _print_state("current", state)
    return 0


def _apply(base_url: str, token: str, body: Dict[str, Any], timeout: float) -> int:
    new_state = _request("POST", base_url, token, body, timeout)
    _print_state("applied", new_state)
    return 0


def cmd_errors(args: argparse.Namespace) -> int:
    base_url, token = _resolve(args)
    return _apply(base_url, token, {"error_rate": args.rate}, args.timeout)


def cmd_latency(args: argparse.Namespace) -> int:
    base_url, token = _resolve(args)
    return _apply(base_url, token, {"latency_ms": args.ms}, args.timeout)


def cmd_outage(args: argparse.Namespace) -> int:
    base_url, token = _resolve(args)
    return _apply(base_url, token, {"outage": True}, args.timeout)


def cmd_set(args: argparse.Namespace) -> int:
    base_url, token = _resolve(args)
    body: Dict[str, Any] = {}
    if args.rate is not None:
        body["error_rate"] = args.rate
    if args.ms is not None:
        body["latency_ms"] = args.ms
    if args.outage is not None:
        body["outage"] = args.outage
    if not body:
        _die(1, "set requires at least one of --rate / --ms / --outage|--no-outage")
    return _apply(base_url, token, body, args.timeout)


def cmd_off(args: argparse.Namespace) -> int:
    """Turn ALL chaos off. Idempotent — converges to the safe baseline."""
    base_url, token = _resolve(args)
    body = {"error_rate": 0.0, "latency_ms": 0, "outage": False}
    return _apply(base_url, token, body, args.timeout)


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def _unit_interval(raw: str) -> float:
    value = float(raw)
    if not 0.0 <= value <= 1.0:
        raise argparse.ArgumentTypeError("rate must be between 0.0 and 1.0")
    return value


def _non_negative_int(raw: str) -> int:
    value = int(raw)
    if value < 0:
        raise argparse.ArgumentTypeError("ms must be >= 0")
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="chaos.py",
        description="App-level chaos driver for demo-api (/admin/chaos).",
    )
    parser.add_argument(
        "--url",
        help="Base URL of demo-api (default: $BASE_URL or %s)." % DEFAULT_URL,
    )
    parser.add_argument(
        "--timeout", type=float, default=5.0,
        help="HTTP timeout in seconds (default: 5).",
    )
    parser.add_argument(
        "--i-know-what-im-doing", dest="force", action="store_true",
        help="Override the production-URL safety guard. Use with extreme care.",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    p_status = sub.add_parser("status", help="Show the current chaos state (GET).")
    p_status.set_defaults(func=cmd_status)

    p_errors = sub.add_parser("errors", help="Inject a 5xx error rate on '/'.")
    p_errors.add_argument("--rate", type=_unit_interval, default=0.5,
                          help="Fraction of '/' requests that 500 (0.0-1.0, default 0.5).")
    p_errors.set_defaults(func=cmd_errors)

    p_latency = sub.add_parser("latency", help="Inject added latency on '/'.")
    p_latency.add_argument("--ms", type=_non_negative_int, default=500,
                           help="Extra latency in milliseconds (>=0, default 500).")
    p_latency.set_defaults(func=cmd_latency)

    p_outage = sub.add_parser("outage", help="Force /readyz -> 503 (pod NotReady).")
    p_outage.set_defaults(func=cmd_outage)

    p_set = sub.add_parser("set", help="Set several knobs at once.")
    p_set.add_argument("--rate", type=_unit_interval, default=None,
                       help="Fraction of '/' requests that 500 (0.0-1.0).")
    p_set.add_argument("--ms", type=_non_negative_int, default=None,
                       help="Extra latency in milliseconds (>=0).")
    outage_group = p_set.add_mutually_exclusive_group()
    outage_group.add_argument("--outage", dest="outage", action="store_true",
                              default=None, help="Force readiness outage on.")
    outage_group.add_argument("--no-outage", dest="outage", action="store_false",
                              default=None, help="Clear readiness outage.")
    p_set.set_defaults(func=cmd_set)

    p_off = sub.add_parser("off", help="Turn ALL chaos off (idempotent recovery).")
    p_off.set_defaults(func=cmd_off)

    return parser


def main(argv: Optional[list] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
