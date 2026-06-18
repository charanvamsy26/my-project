# tests/ — unit tests for the auto-remediation controller

```bash
cd tools/auto-remediation
python3 -m pip install pytest
python3 -m pytest -q          # 42 tests, ~0.2s, no live cluster / Prometheus
```

Everything external is mocked — the Prometheus HTTP query (via a stubbed
`requests.Session` / an autospec'd `PrometheusClient`), the monotonic clock (a
hand-advanced `FakeClock`), and the remediation executor (`remediate` is patched
so no `kubectl`/`argocd`/K8s API is ever called). There is **no real sleeping**
and **no network**.

## Coverage

| Area | What's asserted |
| ---- | --------------- |
| `PrometheusClient.query` | result extraction, trailing-slash handling, query param; raises `PrometheusError` on HTTP ≠ 200, API `status: error`, transport errors. |
| Detection — `alerts` mode | firing series ⇒ breach; empty ⇒ no breach; query targets the configured alert name + `alertstate="firing"`. |
| Detection — `burnrate` mode | burn rate ≥ threshold ⇒ breach; below ⇒ no breach; empty result ⇒ no breach. |
| Detection dispatch | `BURN_QUERY_MODE` routes to the right strategy. |
| Sustain gate | new breach starts a timer; not-yet-sustained waits; cleared breach resets the timer. |
| Remediation trigger | sustained breach ⇒ `remediate` called; cooldown armed + breach window cleared afterward. |
| Cooldown | second sustained breach within the window is suppressed; expires correctly; `in_cooldown` predicate. |
| Backoff | Prometheus error ⇒ backoff decision + error counter; exponential growth then cap; successful query resets the counter. |
| Failure isolation | a remediation exception backs off instead of crashing, and does **not** arm the cooldown. |
| Heartbeat | the readiness heartbeat file is written each `step()`. |
| Remediation dispatch | dry-run executes nothing; restart uses the K8s client when present, else `kubectl`; `MODE=rollback` calls Argo CD; exact `kubectl`/`argocd` argv; `_run_command` raises on non-zero exit. |
| Config / logging | env parsing, `DRY_RUN` defaults true, `_env_bool` truthy/falsey/empty handling, JSON log formatter emits valid JSON with promoted structured fields. |

## Notes

- `tests/test_remediator.py` inserts the parent directory on `sys.path`, so it
  imports `remediator` whether you run pytest from the repo root or from
  `tools/auto-remediation/`.
- The `kubernetes` Python client is **not** required to run the tests — the
  restart-via-client path is patched, and `_k8s_client_available()` is forced in
  the dispatch tests.
