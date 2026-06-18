"""Route-level tests for demo-api.

These run with no DATABASE_URL set, so the service is in stateless mode and
/readyz reports ready. We also assert that metrics are emitted under the exact
names/labels the Prometheus rules + Grafana dashboard query, and that the chaos
fault-injection hooks behave (safe-by-default, counted, token-guarded admin).
"""

import sys
from pathlib import Path

import pytest

# Make src/ importable without installing the package.
SRC = Path(__file__).resolve().parent.parent / "src"
sys.path.insert(0, str(SRC))


@pytest.fixture()
def client(monkeypatch):
    # Ensure stateless mode regardless of the developer's environment.
    # We patch the already-imported module's DATABASE_URL rather than reloading
    # the module, because reloading would re-register the Prometheus metrics
    # into the default registry and raise a "duplicated timeseries" error.
    import app as app_module

    monkeypatch.setattr(app_module, "DATABASE_URL", None)
    # Reset chaos to safe defaults so tests are isolated from each other and
    # from any CHAOS_* env vars in the developer's shell.
    app_module.chaos.update(error_rate=0.0, latency_ms=0, outage=False)
    app_module.app.testing = True
    with app_module.app.test_client() as c:
        yield c


def _metrics_text(client):
    resp = client.get("/metrics")
    assert resp.status_code == 200
    return resp.get_data(as_text=True)


def test_hello(client):
    resp = client.get("/")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["service"] == "demo-api"
    assert body["message"] == "Hello from demo-api"
    # No DB configured -> stateless.
    assert body["stateful"] is False


def test_healthz(client):
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok"}


def test_readyz_stateless_is_ready(client):
    resp = client.get("/readyz")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "ready"
    assert body["database"] == "disabled"


def test_metrics_exposition(client):
    # Generate at least one request so a counter sample exists.
    client.get("/")
    text = _metrics_text(client)
    # Metric families must use the EXACT names the rules/dashboard query.
    assert "http_requests_total" in text
    assert "http_request_duration_seconds_bucket" in text
    assert "http_request_duration_seconds_sum" in text
    assert "http_request_duration_seconds_count" in text
    # Prometheus text format starts metric metadata with HELP/TYPE comments.
    assert "# HELP" in text
    assert "# TYPE" in text


def test_counter_has_contract_labels(client):
    # Hit "/" so a known series exists, then assert the exact label set the
    # rules select on: service="demo-api", path="/", status="200".
    client.get("/")
    text = _metrics_text(client)
    # A counter series carrying exactly these three labels must be present.
    matches = [
        line
        for line in text.splitlines()
        if line.startswith("http_requests_total{")
        and 'service="demo-api"' in line
        and 'path="/"' in line
        and 'status="200"' in line
    ]
    assert matches, f"no matching http_requests_total series in:\n{text}"


def test_status_label_is_raw_numeric_code(client):
    # The rules match status with regexes like status=~"5.." (raw 3-digit
    # codes), so the app MUST emit raw codes, not classes like "2xx"/"5xx".
    client.get("/does-not-exist")  # 404
    text = _metrics_text(client)
    assert 'status="404"' in text
    # And never a status-class form.
    assert 'status="4xx"' not in text
    assert 'status="2xx"' not in text


def test_path_label_is_route_template_not_raw_path(client):
    # Route-template labels keep cardinality bounded; healthz/readyz/metrics are
    # explicitly excluded by the rules via path!~"/healthz|/readyz|/metrics".
    client.get("/healthz")
    text = _metrics_text(client)
    assert 'path="/healthz"' in text


def test_histogram_bucket_carries_le_and_contract_labels(client):
    client.get("/")
    text = _metrics_text(client)
    bucket_lines = [
        line
        for line in text.splitlines()
        if line.startswith("http_request_duration_seconds_bucket{")
        and 'service="demo-api"' in line
        and 'path="/"' in line
        and 'status="200"' in line
        and "le=" in line
    ]
    assert bucket_lines, "histogram buckets must carry service/path/status/le"


def test_unknown_route_returns_404(client):
    resp = client.get("/does-not-exist")
    assert resp.status_code == 404
    assert resp.get_json() == {"error": "not found"}


def test_readyz_with_db_failure_returns_503(client, monkeypatch):
    # Point at an unreachable DB and force a "configured" state without
    # reimporting, to exercise the degraded readiness path.
    import app as app_module

    monkeypatch.setattr(app_module, "DATABASE_URL", "postgresql://bad:bad@127.0.0.1:1/none")
    monkeypatch.setattr(
        app_module,
        "_check_database",
        lambda: (False, "error: OperationalError"),
    )
    resp = client.get("/readyz")
    assert resp.status_code == 503
    body = resp.get_json()
    assert body["status"] == "not-ready"


# --------------------------------------------------------------------------- #
# Chaos / fault injection
# --------------------------------------------------------------------------- #
def test_chaos_off_by_default(client):
    import app as app_module

    state = app_module.chaos.snapshot()
    assert state == {"error_rate": 0.0, "latency_ms": 0, "outage": False}
    # And "/" serves a normal 200 with no chaos configured.
    assert client.get("/").status_code == 200


def test_chaos_error_rate_forces_500_and_is_counted(client):
    import app as app_module

    # error_rate=1.0 -> every "/" request returns 500.
    app_module.chaos.update(error_rate=1.0)
    resp = client.get("/")
    assert resp.status_code == 500
    assert resp.get_json()["error"] == "chaos-injected failure"

    # The injected 500 MUST be reflected in the metrics so the budget burns.
    text = _metrics_text(client)
    burn_series = [
        line
        for line in text.splitlines()
        if line.startswith("http_requests_total{")
        and 'service="demo-api"' in line
        and 'path="/"' in line
        and 'status="500"' in line
    ]
    assert burn_series, "injected 500 must produce a status=\"500\" counter series"


def test_chaos_latency_is_applied_and_observed(client):
    import app as app_module
    import time

    app_module.chaos.update(latency_ms=50)
    start = time.perf_counter()
    resp = client.get("/")
    elapsed = time.perf_counter() - start
    assert resp.status_code == 200
    # At least the injected delay elapsed (with a little slack for scheduling).
    assert elapsed >= 0.045


def test_chaos_outage_makes_readyz_503_but_healthz_ok(client):
    import app as app_module

    app_module.chaos.update(outage=True)
    ready = client.get("/readyz")
    assert ready.status_code == 503
    assert ready.get_json()["reason"] == "chaos-outage"
    # Liveness must stay green during an outage so the pod is NOT restarted.
    assert client.get("/healthz").status_code == 200


# --------------------------------------------------------------------------- #
# Chaos admin endpoint — token-guarded, disabled when no token configured.
# --------------------------------------------------------------------------- #
def test_admin_chaos_disabled_without_token(client, monkeypatch):
    import app as app_module

    monkeypatch.setattr(app_module, "CHAOS_ADMIN_TOKEN", None)
    assert client.get("/admin/chaos").status_code == 404
    assert client.post("/admin/chaos", json={"error_rate": 0.5}).status_code == 404


def test_admin_chaos_requires_correct_token(client, monkeypatch):
    import app as app_module

    monkeypatch.setattr(app_module, "CHAOS_ADMIN_TOKEN", "s3cret")
    # Missing/wrong token -> 401.
    assert client.get("/admin/chaos").status_code == 401
    assert (
        client.get("/admin/chaos", headers={"X-Chaos-Token": "nope"}).status_code
        == 401
    )


def test_admin_chaos_get_and_post_with_token(client, monkeypatch):
    import app as app_module

    monkeypatch.setattr(app_module, "CHAOS_ADMIN_TOKEN", "s3cret")
    headers = {"X-Chaos-Token": "s3cret"}

    # GET returns current state.
    resp = client.get("/admin/chaos", headers=headers)
    assert resp.status_code == 200
    assert resp.get_json() == {"error_rate": 0.0, "latency_ms": 0, "outage": False}

    # POST updates state and echoes it back (clamped to valid ranges).
    resp = client.post(
        "/admin/chaos",
        headers=headers,
        json={"error_rate": 1.5, "latency_ms": 100, "outage": True},
    )
    assert resp.status_code == 200
    body = resp.get_json()
    assert body == {"error_rate": 1.0, "latency_ms": 100, "outage": True}

    # The update actually took effect on "/".
    assert client.get("/").status_code == 500


def test_admin_chaos_accepts_bearer_token(client, monkeypatch):
    import app as app_module

    monkeypatch.setattr(app_module, "CHAOS_ADMIN_TOKEN", "s3cret")
    resp = client.get(
        "/admin/chaos", headers={"Authorization": "Bearer s3cret"}
    )
    assert resp.status_code == 200
