"""Unit tests for the auto-remediation controller.

Everything external is mocked: the Prometheus HTTP query, the clock, and the
remediation executor. No live Prometheus, no live cluster, no real sleeping.

Run:
    cd tools/auto-remediation && python -m pytest -q
"""

from __future__ import annotations

import json
import logging
import os
import sys
from unittest import mock

import pytest
import requests

# Make `remediator` importable regardless of where pytest is invoked from.
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import remediator as rem  # noqa: E402


# --------------------------------------------------------------------------- #
# Helpers / fixtures
# --------------------------------------------------------------------------- #


@pytest.fixture
def cfg(tmp_path):
    """A Config with small, deterministic windows for fast tests."""
    return rem.Config(
        prom_url="http://prom.test:9090",
        burn_query_mode="alerts",
        breach_alert="DemoApiErrorBudgetBurnFast",
        burn_threshold=14.4,
        namespace="demo",
        deployment="demo-api",
        mode="restart",
        dry_run=True,
        poll_seconds=1,
        sustained_seconds=100,
        cooldown_seconds=300,
        argocd_app="demo-api",
        backoff_base_seconds=1.0,
        backoff_max_seconds=8.0,
        http_timeout_seconds=5.0,
        log_level="DEBUG",
    )


@pytest.fixture
def log():
    return rem.build_logger("DEBUG")


class FakeClock:
    """Monotonic clock we advance manually so sustain/cooldown are testable."""

    def __init__(self, start: float = 1000.0):
        self.t = start

    def __call__(self) -> float:
        return self.t

    def advance(self, seconds: float) -> None:
        self.t += seconds


def make_controller(cfg, log, prom, clock, tmp_path):
    return rem.Controller(
        cfg, prom, log, clock=clock,
        heartbeat_path=str(tmp_path / "heartbeat"),
    )


def fake_prom(result):
    """A PrometheusClient whose .query() returns a canned result list."""
    prom = mock.create_autospec(rem.PrometheusClient, instance=True)
    prom.query.return_value = result
    return prom


# --------------------------------------------------------------------------- #
# PrometheusClient.query — HTTP behaviour
# --------------------------------------------------------------------------- #


def _http_response(status_code=200, json_body=None, text=""):
    resp = mock.Mock()
    resp.status_code = status_code
    resp.text = text
    if json_body is None:
        resp.json.side_effect = ValueError("no json")
    else:
        resp.json.return_value = json_body
    return resp


def test_query_success_returns_result_list():
    session = mock.Mock()
    session.get.return_value = _http_response(
        json_body={"status": "success", "data": {"result": [{"metric": {}, "value": [0, "1"]}]}}
    )
    client = rem.PrometheusClient("http://prom:9090/", session=session)
    out = client.query("up")
    assert out == [{"metric": {}, "value": [0, "1"]}]
    # base_url trailing slash is stripped; query passed as a param.
    args, kwargs = session.get.call_args
    assert args[0] == "http://prom:9090/api/v1/query"
    assert kwargs["params"] == {"query": "up"}


def test_query_http_error_raises_prometheus_error():
    session = mock.Mock()
    session.get.return_value = _http_response(status_code=503, text="unavailable")
    client = rem.PrometheusClient("http://prom:9090", session=session)
    with pytest.raises(rem.PrometheusError):
        client.query("up")


def test_query_api_status_error_raises():
    session = mock.Mock()
    session.get.return_value = _http_response(
        json_body={"status": "error", "error": "bad query"}
    )
    client = rem.PrometheusClient("http://prom:9090", session=session)
    with pytest.raises(rem.PrometheusError):
        client.query("???")


def test_query_transport_error_raises():
    session = mock.Mock()
    session.get.side_effect = requests.ConnectionError("refused")
    client = rem.PrometheusClient("http://prom:9090", session=session)
    with pytest.raises(rem.PrometheusError):
        client.query("up")


# --------------------------------------------------------------------------- #
# Breach detection — both strategies
# --------------------------------------------------------------------------- #


def test_detect_via_alerts_firing_is_breach(cfg):
    prom = fake_prom([{"metric": {"alertname": "DemoApiErrorBudgetBurnFast"}, "value": [0, "1"]}])
    breached, detail = rem.detect_via_alerts(prom, cfg)
    assert breached is True
    assert detail["strategy"] == "alerts"
    assert detail["firing_series"] == 1
    # The query targets the configured alert name, firing state only.
    assert 'alertname="DemoApiErrorBudgetBurnFast"' in detail["promql"]
    assert 'alertstate="firing"' in detail["promql"]


def test_detect_via_alerts_no_series_is_not_breach(cfg):
    prom = fake_prom([])
    breached, detail = rem.detect_via_alerts(prom, cfg)
    assert breached is False
    assert detail["firing_series"] == 0


def test_detect_via_burnrate_above_threshold_is_breach(cfg):
    cfg.burn_query_mode = "burnrate"
    prom = fake_prom([{"metric": {}, "value": [0, "20.5"]}])  # 20.5x > 14.4x
    breached, detail = rem.detect_via_burnrate(prom, cfg)
    assert breached is True
    assert detail["burn_rate"] == pytest.approx(20.5)
    assert detail["burn_threshold"] == 14.4


def test_detect_via_burnrate_below_threshold_is_not_breach(cfg):
    cfg.burn_query_mode = "burnrate"
    prom = fake_prom([{"metric": {}, "value": [0, "3.0"]}])  # below 14.4x
    breached, detail = rem.detect_via_burnrate(prom, cfg)
    assert breached is False
    assert detail["burn_rate"] == pytest.approx(3.0)


def test_detect_via_burnrate_empty_result_is_not_breach(cfg):
    cfg.burn_query_mode = "burnrate"
    prom = fake_prom([])  # no traffic / quiet service -> no series
    breached, detail = rem.detect_via_burnrate(prom, cfg)
    assert breached is False
    assert detail["burn_rate"] is None


def test_detect_breach_dispatches_on_mode(cfg):
    prom = fake_prom([])
    cfg.burn_query_mode = "burnrate"
    with mock.patch.object(rem, "detect_via_burnrate", return_value=(False, {"s": "b"})) as br, \
         mock.patch.object(rem, "detect_via_alerts", return_value=(False, {"s": "a"})) as al:
        rem.detect_breach(prom, cfg)
        br.assert_called_once()
        al.assert_not_called()


# --------------------------------------------------------------------------- #
# Controller decision logic — sustain, cooldown, backoff
# --------------------------------------------------------------------------- #


def test_no_breach_resets_sustain_timer(cfg, log, tmp_path):
    clock = FakeClock()
    prom = fake_prom([])  # nothing firing
    ctrl = make_controller(cfg, log, prom, clock, tmp_path)
    decision = ctrl.step()
    assert decision["decision"] == "no_breach"
    assert ctrl.breach_since is None


def test_breach_not_yet_sustained_waits(cfg, log, tmp_path):
    clock = FakeClock()
    prom = fake_prom([{"metric": {}, "value": [0, "1"]}])  # firing
    ctrl = make_controller(cfg, log, prom, clock, tmp_path)
    decision = ctrl.step()
    assert decision["decision"] == "waiting_sustain"
    assert ctrl.breach_since == clock.t  # timer started


def test_sustained_breach_triggers_remediation(cfg, log, tmp_path):
    clock = FakeClock()
    prom = fake_prom([{"metric": {}, "value": [0, "1"]}])  # firing every poll
    ctrl = make_controller(cfg, log, prom, clock, tmp_path)

    with mock.patch.object(rem, "remediate", return_value={"action": "rollout_restart", "executed": False}) as r:
        ctrl.step()                       # t=1000: starts timer (waiting)
        assert ctrl.breach_since == 1000.0
        clock.advance(cfg.sustained_seconds)  # now sustained
        decision = ctrl.step()
        assert decision["decision"] == "remediated"
        r.assert_called_once()
    # After acting: cooldown armed, breach window cleared.
    assert ctrl.last_action_at == clock.t
    assert ctrl.breach_since is None


def test_cleared_breach_between_polls_resets_timer(cfg, log, tmp_path):
    clock = FakeClock()
    firing = [{"metric": {}, "value": [0, "1"]}]
    prom = mock.create_autospec(rem.PrometheusClient, instance=True)
    prom.query.side_effect = [firing, [], firing]  # firing, cleared, firing again
    ctrl = make_controller(cfg, log, prom, clock, tmp_path)

    ctrl.step()                # breach starts
    assert ctrl.breach_since is not None
    clock.advance(10)
    ctrl.step()                # cleared -> timer reset
    assert ctrl.breach_since is None
    clock.advance(10)
    d = ctrl.step()            # firing again -> brand new timer, not sustained
    assert d["decision"] == "waiting_sustain"


def test_cooldown_suppresses_second_remediation(cfg, log, tmp_path):
    clock = FakeClock()
    prom = fake_prom([{"metric": {}, "value": [0, "1"]}])
    ctrl = make_controller(cfg, log, prom, clock, tmp_path)

    with mock.patch.object(rem, "remediate", return_value={"action": "rollout_restart", "executed": False}):
        ctrl.step()                              # start timer
        clock.advance(cfg.sustained_seconds)
        first = ctrl.step()                      # remediate
        assert first["decision"] == "remediated"

        # Breach still firing; advance less than cooldown.
        clock.advance(cfg.sustained_seconds)     # re-arm a sustained breach window
        # step() at this point: breach_since was reset, so it re-starts the timer.
        ctrl.step()
        clock.advance(cfg.sustained_seconds)
        second = ctrl.step()                     # sustained again, but cooldown active
        assert second["decision"] == "cooldown"
        assert second["cooldown_remaining_seconds"] > 0


def test_cooldown_expires_allows_remediation_again(cfg, log, tmp_path):
    clock = FakeClock()
    prom = fake_prom([{"metric": {}, "value": [0, "1"]}])
    ctrl = make_controller(cfg, log, prom, clock, tmp_path)

    with mock.patch.object(rem, "remediate", return_value={"action": "rollout_restart", "executed": False}):
        ctrl.step()
        clock.advance(cfg.sustained_seconds)
        ctrl.step()                              # first remediation -> cooldown armed
        # Jump past the cooldown window entirely.
        clock.advance(cfg.cooldown_seconds + 1)
        ctrl.step()                              # new sustained timer starts
        clock.advance(cfg.sustained_seconds)
        again = ctrl.step()
        assert again["decision"] == "remediated"


def test_in_cooldown_predicate(cfg, log, tmp_path):
    clock = FakeClock()
    ctrl = make_controller(cfg, log, fake_prom([]), clock, tmp_path)
    assert ctrl.in_cooldown(clock.t) is False     # never acted
    ctrl.last_action_at = clock.t
    assert ctrl.in_cooldown(clock.t + 1) is True
    assert ctrl.in_cooldown(clock.t + cfg.cooldown_seconds) is False


def test_prometheus_error_triggers_backoff(cfg, log, tmp_path):
    clock = FakeClock()
    prom = mock.create_autospec(rem.PrometheusClient, instance=True)
    prom.query.side_effect = rem.PrometheusError("prom down")
    ctrl = make_controller(cfg, log, prom, clock, tmp_path)
    d = ctrl.step()
    assert d["decision"] == "backoff"
    assert ctrl.consecutive_errors == 1
    assert d["backoff_seconds"] >= 0


def test_backoff_grows_then_caps(cfg, log, tmp_path):
    clock = FakeClock()
    ctrl = make_controller(cfg, log, fake_prom([]), clock, tmp_path)
    # Force determinism on the jitter so we test the cap, not the randomness.
    with mock.patch.object(rem.random, "uniform", side_effect=lambda lo, hi: hi):
        ctrl.consecutive_errors = 1
        assert ctrl.backoff_delay() == pytest.approx(1.0)   # base
        ctrl.consecutive_errors = 2
        assert ctrl.backoff_delay() == pytest.approx(2.0)
        ctrl.consecutive_errors = 3
        assert ctrl.backoff_delay() == pytest.approx(4.0)
        ctrl.consecutive_errors = 4
        assert ctrl.backoff_delay() == pytest.approx(8.0)
        ctrl.consecutive_errors = 50                          # would overflow
        assert ctrl.backoff_delay() == pytest.approx(8.0)     # capped


def test_successful_query_resets_backoff(cfg, log, tmp_path):
    clock = FakeClock()
    prom = mock.create_autospec(rem.PrometheusClient, instance=True)
    prom.query.side_effect = [rem.PrometheusError("boom"), []]
    ctrl = make_controller(cfg, log, prom, clock, tmp_path)
    ctrl.step()                       # error -> errors=1
    assert ctrl.consecutive_errors == 1
    ctrl.step()                       # success -> reset
    assert ctrl.consecutive_errors == 0


def test_remediation_failure_backs_off_not_crash(cfg, log, tmp_path):
    clock = FakeClock()
    prom = fake_prom([{"metric": {}, "value": [0, "1"]}])
    ctrl = make_controller(cfg, log, prom, clock, tmp_path)
    with mock.patch.object(rem, "remediate", side_effect=RuntimeError("kube down")):
        ctrl.step()
        clock.advance(cfg.sustained_seconds)
        d = ctrl.step()
        assert d["decision"] == "remediation_failed"
        assert ctrl.consecutive_errors == 1
        # cooldown NOT armed because the action failed.
        assert ctrl.last_action_at is None


def test_heartbeat_written_each_step(cfg, log, tmp_path):
    clock = FakeClock()
    hb = tmp_path / "heartbeat"
    prom = fake_prom([])
    ctrl = rem.Controller(cfg, prom, log, clock=clock, heartbeat_path=str(hb))
    assert not hb.exists()
    ctrl.step()
    assert hb.exists()
    assert float(hb.read_text()) > 0


# --------------------------------------------------------------------------- #
# Remediation dispatch — dry-run vs execute, restart vs rollback
# --------------------------------------------------------------------------- #


def test_remediate_dry_run_does_not_execute(cfg, log):
    cfg.dry_run = True
    cfg.mode = "restart"
    with mock.patch.object(rem, "restart_via_kubectl") as kub, \
         mock.patch.object(rem, "restart_via_k8s_client") as kc, \
         mock.patch.object(rem, "_k8s_client_available", return_value=False):
        action = rem.remediate(cfg, log)
    assert action["executed"] is False
    assert action["action"] == "rollout_restart"
    kub.assert_not_called()
    kc.assert_not_called()


def test_remediate_restart_uses_kubectl_when_client_absent(cfg, log):
    cfg.dry_run = False
    cfg.mode = "restart"
    with mock.patch.object(rem, "_k8s_client_available", return_value=False), \
         mock.patch.object(rem, "restart_via_kubectl") as kub:
        action = rem.remediate(cfg, log)
    assert action["via"] == "kubectl"
    assert action["executed"] is True
    kub.assert_called_once_with(cfg, log)


def test_remediate_restart_uses_client_when_present(cfg, log):
    cfg.dry_run = False
    cfg.mode = "restart"
    with mock.patch.object(rem, "_k8s_client_available", return_value=True), \
         mock.patch.object(rem, "restart_via_k8s_client") as kc:
        action = rem.remediate(cfg, log)
    assert action["via"] == "kubernetes-client"
    assert action["executed"] is True
    kc.assert_called_once_with(cfg, log)


def test_remediate_rollback_mode_calls_argocd(cfg, log):
    cfg.dry_run = False
    cfg.mode = "rollback"
    with mock.patch.object(rem, "rollback_via_argocd") as ag:
        action = rem.remediate(cfg, log)
    assert action["action"] == "argocd_rollback"
    assert action["executed"] is True
    ag.assert_called_once_with(cfg, log)


def test_restart_via_kubectl_builds_correct_command(cfg, log):
    cfg.namespace = "demo"
    cfg.deployment = "demo-api"
    with mock.patch.object(rem, "_run_command") as run:
        rem.restart_via_kubectl(cfg, log)
    run.assert_called_once_with(
        ["kubectl", "rollout", "restart", "deployment/demo-api", "-n", "demo"]
    )


def test_rollback_via_argocd_builds_correct_command(cfg, log):
    cfg.argocd_app = "demo-api"
    with mock.patch.object(rem, "_run_command") as run:
        rem.rollback_via_argocd(cfg, log)
    run.assert_called_once_with(["argocd", "app", "rollback", "demo-api"])


def test_run_command_raises_on_nonzero():
    completed = mock.Mock(returncode=1, stderr="boom", stdout="")
    with mock.patch.object(rem.subprocess, "run", return_value=completed):
        with pytest.raises(RuntimeError):
            rem._run_command(["false"])


def test_run_command_ok_on_zero():
    completed = mock.Mock(returncode=0, stderr="", stdout="ok")
    with mock.patch.object(rem.subprocess, "run", return_value=completed):
        rem._run_command(["true"])  # no exception


# --------------------------------------------------------------------------- #
# Config + logging
# --------------------------------------------------------------------------- #


def test_config_reads_env(monkeypatch):
    monkeypatch.setenv("PROM_URL", "http://x:9090")
    monkeypatch.setenv("NAMESPACE", "prod")
    monkeypatch.setenv("DEPLOYMENT", "svc")
    monkeypatch.setenv("DRY_RUN", "false")
    monkeypatch.setenv("MODE", "rollback")
    monkeypatch.setenv("BURN_THRESHOLD", "6")
    monkeypatch.setenv("COOLDOWN_SECONDS", "900")
    c = rem.Config()
    assert c.prom_url == "http://x:9090"
    assert c.namespace == "prod"
    assert c.deployment == "svc"
    assert c.dry_run is False
    assert c.mode == "rollback"
    assert c.burn_threshold == 6.0
    assert c.cooldown_seconds == 900


def test_dry_run_defaults_true(monkeypatch):
    monkeypatch.delenv("DRY_RUN", raising=False)
    assert rem.Config().dry_run is True


@pytest.mark.parametrize("raw,expected", [
    ("true", True), ("True", True), ("1", True), ("yes", True), ("on", True),
    ("false", False), ("0", False), ("no", False), ("", True),  # empty -> default
])
def test_env_bool_parsing(monkeypatch, raw, expected):
    monkeypatch.setenv("FLAG", raw)
    assert rem._env_bool("FLAG", True) is expected


def test_json_log_formatter_emits_valid_json():
    logger = rem.build_logger("INFO")
    record = logging.LogRecord(
        name="auto-remediation", level=logging.INFO, pathname=__file__,
        lineno=1, msg="hello", args=(), exc_info=None,
    )
    record.namespace = "demo"
    record.decision = "remediated"
    line = rem.JsonLogFormatter().format(record)
    obj = json.loads(line)
    assert obj["message"] == "hello"
    assert obj["service"] == "auto-remediation"
    assert obj["level"] == "INFO"
    assert obj["namespace"] == "demo"
    assert obj["decision"] == "remediated"
    assert "timestamp" in obj
