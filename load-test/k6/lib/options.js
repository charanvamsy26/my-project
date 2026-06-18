// =============================================================================
// Shared k6 helpers + option fragments for the demo-api reliability demo.
// -----------------------------------------------------------------------------
// Both steady.js and burn.js import from here so the two scenarios stay in
// lock-step with the SLO contract and the canonical metric/endpoint surface of
// demo-api (app/src/app.py).
//
// SLO contract (source of truth: observability/slo/slo.yaml + the Prometheus
// slo-rules.yaml):
//   * Availability objective: 99.9% of valid (non-probe, non-5xx) requests
//     succeed over a rolling 30d window  =>  0.1% error budget.
//   * Latency: demo-api's histogram buckets put the p99 SLO at 500ms
//     (the 0.5s bucket; DemoApiHighLatencyP99 fires above it).
//
// The thresholds below assert against those numbers. steady.js is tuned to
// PASS them comfortably; burn.js is tuned to BLOW them (that is the demo).
// =============================================================================

// -----------------------------------------------------------------------------
// BASE_URL: where the load is sent. Parameterized so the same script runs:
//   * locally:    kubectl port-forward svc/demo-api 8000:80
//                 BASE_URL=http://localhost:8000 k6 run k6/steady.js
//   * in-cluster: BASE_URL=http://demo-api.demo.svc.cluster.local
//                 (Service port 80 -> container 8000; see k8s/k6-job.yaml)
//
// NOTE on the Service name: the demo-api Helm chart names the Service after the
// Helm *fullname* (e.g. `demo-api-demo-api` for release `demo-api`). The whole
// demo assumes you expose it as `demo-api` — either by installing the chart with
// `--set fullnameOverride=demo-api` or `helm install demo-api ... --set
// nameOverride=""` so the fullname collapses to `demo-api`. Adjust BASE_URL /
// the Service name in k8s/k6-job.yaml if your release name differs.
// -----------------------------------------------------------------------------
export const BASE_URL = (__ENV.BASE_URL || 'http://localhost:8000').replace(/\/+$/, '');

// SLO targets, kept in one place so thresholds and docs cannot drift apart.
export const SLO = {
  // p99 latency budget in milliseconds (aligns with the 0.5s histogram bucket).
  P99_LATENCY_MS: 500,
  // Availability objective -> max tolerated error ratio over the window.
  // 99.9% success => 0.1% errors => 0.001 as a fraction.
  MAX_ERROR_RATIO: 0.001,
};

// Standard HTTP params for every request: a short timeout and a tag that lets
// us slice k6's own metrics per endpoint without exploding cardinality.
export function reqParams(name) {
  return {
    timeout: '10s',
    tags: { endpoint: name || 'root' },
  };
}

// A single "hit the root path" request. The chaos hooks in demo-api live on
// "/", so this is the path both scenarios drive. Returns the k6 Response.
export function hitRoot(http) {
  return http.get(`${BASE_URL}/`, reqParams('root'));
}

// Liveness/readiness helpers — handy for warm-up / sanity checks. These are
// EXCLUDED from the SLO in the Prometheus rules (path!~"/healthz|/readyz|...")
// so do not count them toward error/latency thresholds in the scenarios.
export function hitHealthz(http) {
  return http.get(`${BASE_URL}/healthz`, reqParams('healthz'));
}

export function hitReadyz(http) {
  return http.get(`${BASE_URL}/readyz`, reqParams('readyz'));
}

// Shared "is this response good?" predicate. The SLO counts any non-5xx as a
// success (matches status=~"5.." being the only "bad" class in slo.yaml), so a
// 4xx is NOT an SLO error. We treat 2xx/3xx/4xx as good, 5xx as bad.
export function isSuccess(res) {
  return res.status > 0 && res.status < 500;
}

// summaryTrendStats: percentiles we care about in the end-of-run summary so
// p99 is always printed next to the threshold that gates on it.
export const summaryTrendStats = ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'];
