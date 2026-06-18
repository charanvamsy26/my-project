// =============================================================================
// burn.js — the "red" load scenario. THIS IS DESIGNED TO FAIL.
// -----------------------------------------------------------------------------
// What it proves: the observability + SLO stack actually CATCHES a bad release.
// It deliberately burns demo-api's error budget two ways, then asserts the SLO
// thresholds — which are EXPECTED TO FAIL (k6 exits non-zero). That failure is
// the whole point: it demonstrates the chaos hooks, the metrics, the Prometheus
// SLO burn-rate alerts (DemoApiAvailabilitySLO) and the Grafana panels lighting
// up end-to-end.
//
//   1. It ramps a ramping-arrival-rate well past a comfortable level.
//   2. It (optionally, and recommended) flips demo-api's chaos knobs on for the
//      "/" path via the guarded /admin/chaos endpoint, so the server injects
//      500s and added latency that flow through the normal metrics path and burn
//      the budget. See app/src/app.py (CHAOS_ERROR_RATE / CHAOS_LATENCY_MS).
//
// EXPECTED RESULT: thresholds FAIL -> k6 exits non-zero. In CI/demo this is the
// success criterion (the budget burned, the alerts fired). Do NOT "fix" these
// thresholds to pass; they intentionally mirror the SLO that this run violates.
//
// Two ways to drive the errors:
//   (A) Server-side chaos (preferred, most realistic): set CHAOS_TOKEN so this
//       script toggles /admin/chaos on at start and off at teardown. Requires
//       demo-api to be started with CHAOS_ADMIN_TOKEN=<same value>.
//         BASE_URL=http://localhost:8000 CHAOS_TOKEN=devtoken \
//           CHAOS_ERROR_RATE=0.25 CHAOS_LATENCY_MS=800 k6 run k6/burn.js
//   (B) Pure overload: leave CHAOS_TOKEN unset and just ramp hard; if the
//       deployment is small enough, saturation alone pushes p99 over budget.
//
// Run locally:
//   kubectl port-forward svc/demo-api 8000:80
//   BASE_URL=http://localhost:8000 CHAOS_TOKEN=devtoken k6 run k6/burn.js
//
// Run in-cluster: see k8s/k6-job.yaml (toggle the BURN command + env there).
// =============================================================================

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';
import {
  BASE_URL,
  SLO,
  hitRoot,
  isSuccess,
  reqParams,
  summaryTrendStats,
} from './lib/options.js';

// ---- Tunables ---------------------------------------------------------------
// Server-side chaos: only applied when CHAOS_TOKEN is provided (and demo-api was
// launched with a matching CHAOS_ADMIN_TOKEN). error_rate is a fraction [0,1].
const CHAOS_TOKEN = __ENV.CHAOS_TOKEN || '';
const CHAOS_ERROR_RATE = Number(__ENV.CHAOS_ERROR_RATE || 0.25); // 25% of "/" -> 500
const CHAOS_LATENCY_MS = Number(__ENV.CHAOS_LATENCY_MS || 800);  // +800ms (> 500ms SLO)

// Load shape. Defaults ramp from a sane base up to an aggressive peak so even
// without chaos a small deployment will likely breach the latency SLO.
const PEAK_RATE = Number(__ENV.PEAK_RATE || 150);   // requests/sec at the peak
const PREALLOC_VUS = Number(__ENV.PREALLOC_VUS || 50);
const MAX_VUS = Number(__ENV.MAX_VUS || 300);

const sloErrors = new Rate('slo_errors');

export const options = {
  scenarios: {
    burn: {
      executor: 'ramping-arrival-rate',
      startRate: 10,
      timeUnit: '1s',
      preAllocatedVUs: PREALLOC_VUS,
      maxVUs: MAX_VUS,
      stages: [
        { target: Math.round(PEAK_RATE * 0.3), duration: '30s' }, // warm ramp
        { target: PEAK_RATE, duration: '1m' },                    // push to peak
        { target: PEAK_RATE, duration: '1m' },                    // hold at peak
        { target: 0, duration: '20s' },                           // ramp down
      ],
      gracefulStop: '15s',
    },
  },

  // ---- SLO thresholds: EXPECTED TO FAIL -----------------------------------
  // These are the SAME SLO numbers steady.js asserts. Under burn conditions the
  // p99 latency and/or error ratio exceed them, so k6 reports threshold
  // breaches and exits non-zero. abortOnFail is intentionally OFF so the full
  // run completes and the budget visibly burns on the dashboards/alerts.
  thresholds: {
    // EXPECTED FAIL: injected latency (+800ms) and/or saturation pushes p99 over 500ms.
    'http_req_duration{endpoint:root}': [
      { threshold: `p(99)<${SLO.P99_LATENCY_MS}`, abortOnFail: false },
    ],
    // EXPECTED FAIL: 5xx ratio blows past the 0.1% budget (chaos error_rate ~25%).
    slo_errors: [
      { threshold: `rate<${SLO.MAX_ERROR_RATIO}`, abortOnFail: false },
    ],
    // EXPECTED FAIL: k6's own failure rate climbs well above the SLO budget too.
    http_req_failed: [
      { threshold: 'rate<0.01', abortOnFail: false },
    ],
  },

  summaryTrendStats,
  tags: { scenario: 'burn', service: 'demo-api' },
};

// Turn server-side chaos ON before the scored scenario. No-op (with a warning)
// when CHAOS_TOKEN is unset — pure-overload mode (B) still runs.
export function setup() {
  if (!CHAOS_TOKEN) {
    console.warn(
      'burn.js: CHAOS_TOKEN unset -> running in PURE-OVERLOAD mode (no /admin/chaos). ' +
      'Set CHAOS_TOKEN (and start demo-api with a matching CHAOS_ADMIN_TOKEN) to inject 500s/latency.'
    );
    return { chaosEnabled: false, base: BASE_URL };
  }

  const res = http.post(
    `${BASE_URL}/admin/chaos`,
    JSON.stringify({ error_rate: CHAOS_ERROR_RATE, latency_ms: CHAOS_LATENCY_MS, outage: false }),
    {
      headers: { 'Content-Type': 'application/json', 'X-Chaos-Token': CHAOS_TOKEN },
      tags: { endpoint: 'admin' },
    }
  );
  const ok = check(res, {
    'setup: /admin/chaos accepted (200)': (r) => r.status === 200,
  });
  if (!ok) {
    console.warn(
      `burn.js: /admin/chaos returned ${res.status} (need a valid CHAOS_TOKEN + CHAOS_ADMIN_TOKEN). ` +
      'Falling back to PURE-OVERLOAD mode.'
    );
    return { chaosEnabled: false, base: BASE_URL };
  }
  console.log(`burn.js: chaos ON (error_rate=${CHAOS_ERROR_RATE}, latency_ms=${CHAOS_LATENCY_MS})`);
  return { chaosEnabled: true, base: BASE_URL };
}

export default function () {
  const res = hitRoot(http);

  const bad = !isSuccess(res); // 5xx is the only SLO "bad"
  sloErrors.add(bad);

  // We do NOT 'check' for 2xx here as a pass/fail gate — under burn we EXPECT
  // 5xx. The threshold block is the contract; these checks are just visibility.
  check(res, {
    'got a response': (r) => r.status !== 0,
    'is 5xx (chaos/overload)': (r) => r.status >= 500,
  });

  sleep(0.05);
}

// Always reset chaos back OFF so a failed/aborted run does not leave demo-api
// degraded. Safe to call even if setup did not enable it.
export function teardown(data) {
  if (data && data.chaosEnabled) {
    const res = http.post(
      `${BASE_URL}/admin/chaos`,
      JSON.stringify({ error_rate: 0.0, latency_ms: 0, outage: false }),
      {
        headers: { 'Content-Type': 'application/json', 'X-Chaos-Token': CHAOS_TOKEN },
        tags: { endpoint: 'admin' },
      }
    );
    console.log(`burn.js: chaos reset OFF (status ${res.status})`);
  }
  console.log(
    'burn.js finished. Threshold FAILURES above are EXPECTED — the error budget was burned on purpose.'
  );
}
