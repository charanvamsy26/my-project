// =============================================================================
// steady.js — the "green" load scenario.
// -----------------------------------------------------------------------------
// What it proves: under a steady, modest request rate WELL within demo-api's
// capacity and with chaos OFF, the service stays inside its SLO. The thresholds
// below assert p99 latency < 500ms and the SLO error ratio < 0.1%. With chaos
// disabled this run is EXPECTED TO PASS (k6 exits 0), which is the baseline the
// burn scenario is contrasted against.
//
// Run locally:
//   kubectl port-forward svc/demo-api 8000:80
//   BASE_URL=http://localhost:8000 k6 run k6/steady.js
//
// Run in-cluster: see k8s/k6-job.yaml (mounts this file via ConfigMap).
//
// Tuning: constant-arrival-rate at a low RPS keeps the offered load far below
// what a 2+ replica deployment handles, so latency/errors stay flat. Bump RATE
// via the RATE env var if your cluster is bigger; the thresholds are absolute
// (SLO-derived), not relative to the rate.
// =============================================================================

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';
import {
  BASE_URL,
  SLO,
  hitRoot,
  hitHealthz,
  isSuccess,
  summaryTrendStats,
} from './lib/options.js';

// Tunables (overridable via env without editing the script).
const RATE = Number(__ENV.RATE || 20);        // requests/sec offered to "/"
const DURATION = __ENV.DURATION || '2m';      // steady-state duration
const PREALLOC_VUS = Number(__ENV.PREALLOC_VUS || 20);
const MAX_VUS = Number(__ENV.MAX_VUS || 50);

// Custom SLO-shaped error rate: fraction of "/" requests that returned 5xx.
// This mirrors the Prometheus SLI (bad 5xx / total) so the k6 threshold and the
// server-side burn alert are measuring the same thing.
const sloErrors = new Rate('slo_errors');

export const options = {
  // Open model: hold a fixed arrival rate regardless of latency, so a slowdown
  // shows up as a latency/queue signal rather than silently lowering throughput.
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: PREALLOC_VUS,
      maxVUs: MAX_VUS,
      gracefulStop: '15s',
    },
  },

  // ---- SLO thresholds: these are the pass/fail contract -------------------
  // EXPECTED RESULT: all PASS (k6 exits 0) when chaos is OFF.
  thresholds: {
    // p99 of demo-api's served latency must stay under the 500ms SLO. We gate on
    // the per-endpoint trend tagged endpoint:root so probe requests do not skew it.
    'http_req_duration{endpoint:root}': [`p(99)<${SLO.P99_LATENCY_MS}`],
    // SLO error budget: < 0.1% of valid requests may be 5xx.
    slo_errors: [`rate<${SLO.MAX_ERROR_RATIO}`],
    // Belt-and-suspenders: k6's own request-failure rate (transport + >=400)
    // stays tiny. Slightly looser than the SLO ratio to tolerate the odd blip.
    http_req_failed: ['rate<0.01'],
  },

  summaryTrendStats,

  // Identify this run in any external output (e.g. k6 -> Prometheus remote write).
  tags: { scenario: 'steady', service: 'demo-api' },
};

// One-time warm-up + sanity check: confirm the target is reachable and ready
// before the scored scenario starts hammering it.
export function setup() {
  const live = hitHealthz(http);
  check(live, { 'setup: /healthz is 200': (r) => r.status === 200 });
  return { startedAt: new Date().toISOString(), base: BASE_URL };
}

export default function () {
  const res = hitRoot(http);

  // Record the SLO-shaped error signal: a 5xx is the only "bad" outcome.
  const bad = !isSuccess(res);
  sloErrors.add(bad);

  check(res, {
    'status is 2xx': (r) => r.status >= 200 && r.status < 300,
    'has demo-api body': (r) => r.body && String(r.body).includes('demo-api'),
  });

  // Light pacing inside the iteration; the arrival-rate executor controls the
  // overall offered RPS, this just avoids a tight CPU spin per VU.
  sleep(0.1);
}

export function teardown(data) {
  // Purely informational; helps when reading CI logs.
  console.log(`steady scenario finished against ${data.base} (started ${data.startedAt})`);
}
