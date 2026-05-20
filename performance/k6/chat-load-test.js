/**
 * UNAgent — k6 chat load test
 *
 * Simulates the end-to-end chat flow through chat-orch against a
 * deterministic LLM mock (50 ms fixed delay). Ramps from 10 to 750 VUs
 * over 12 minutes to produce a performance curve.
 *
 * Run inside docker-compose.perf.yml:
 *   docker compose -f docker-compose.yml -f docker-compose.perf.yml \
 *     run --rm k6
 *
 * Run locally against a running stack:
 *   CHAT_ORCH_URL=http://localhost:8000 k6 run \
 *     --out influxdb=http://localhost:8086/k6 \
 *     performance/k6/chat-load-test.js
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

// ── Custom metrics ────────────────────────────────────────────────────────────
const chatE2eLatency = new Trend('chat_e2e_latency_ms', true);
const chatErrors     = new Rate('chat_error_rate');
const chatRequests   = new Counter('chat_total_requests');

// ── Configuration ─────────────────────────────────────────────────────────────
const CHAT_ORCH_URL = __ENV.CHAT_ORCH_URL || 'http://chat-orch:3000';
const TENANT_ID     = __ENV.TENANT_ID     || 'demo-tenant';

// Simulated user messages — varied to produce realistic prompt diversity
const USER_MESSAGES = [
  'Necesito agendar una cita médica con un internista',
  '¿Qué médicos tienen disponibilidad esta semana?',
  'Quiero cancelar mi cita del próximo martes',
  '¿Cuáles son los horarios disponibles del doctor García?',
  'Tengo dolor de cabeza y quiero ver a un neurólogo',
  'Necesito una cita urgente para mañana',
  '¿Pueden confirmarme mi cita del viernes?',
  'Busco un médico en la sede norte que atienda los lunes',
];

// ── Load profile ──────────────────────────────────────────────────────────────
// Total duration: 16 minutes
// Levels: 10 → 50 → 100 → 200 → 500 → 750 → 1000 → 2000 VUs
export const options = {
  stages: [
    { duration: '1m', target: 10   },  // ramp to   10 VUs
    { duration: '1m', target: 10   },  // hold       10 VUs
    { duration: '1m', target: 50   },  // ramp to   50 VUs
    { duration: '1m', target: 50   },  // hold       50 VUs
    { duration: '1m', target: 100  },  // ramp to  100 VUs
    { duration: '1m', target: 100  },  // hold      100 VUs
    { duration: '1m', target: 200  },  // ramp to  200 VUs
    { duration: '1m', target: 200  },  // hold      200 VUs
    { duration: '1m', target: 500  },  // ramp to  500 VUs
    { duration: '1m', target: 500  },  // hold      500 VUs
    { duration: '1m', target: 750  },  // ramp to  750 VUs
    { duration: '1m', target: 750  },  // hold      750 VUs
    { duration: '1m', target: 1000 },  // ramp to 1000 VUs
    { duration: '1m', target: 1000 },  // hold     1000 VUs
    { duration: '1m', target: 2000 },  // ramp to 2000 VUs
    { duration: '1m', target: 2000 },  // hold     2000 VUs
  ],

  thresholds: {
    // Overall HTTP failure rate must stay below 5 %
    http_req_failed:         ['rate<0.05'],
    // 95th percentile latency must be under 2000 ms (800 ms mock + overhead headroom)
    http_req_duration:       ['p(95)<2000'],
    // Custom end-to-end metric same bound
    chat_e2e_latency_ms:     ['p(95)<2000'],
    // Chat-specific error rate
    chat_error_rate:         ['rate<0.05'],
  },
};

// ── Helpers ───────────────────────────────────────────────────────────────────
function randomMessage() {
  return USER_MESSAGES[Math.floor(Math.random() * USER_MESSAGES.length)];
}

// ── Default function (one VU iteration) ──────────────────────────────────────
export default function () {
  const message = randomMessage();

  group('POST /v1/chat', () => {
    // No pasamos session_id: chat-orch crea una sesión nueva y devuelve el id.
    // Pasar un id externo causa 404 porque conversation-chat no conoce la sesión.
    const payload = JSON.stringify({
      tenant_id: TENANT_ID,
      message:   message,
    });

    const params = {
      headers: { 'Content-Type': 'application/json' },
      timeout: '15s',
      tags:    { endpoint: 'chat' },
    };

    const start = Date.now();
    const res   = http.post(`${CHAT_ORCH_URL}/v1/chat`, payload, params);
    const elapsed = Date.now() - start;

    chatE2eLatency.add(elapsed);
    chatRequests.add(1);

    const ok = check(res, {
      'HTTP 200':           (r) => r.status === 200,
      'body is JSON':       (r) => {
        try { JSON.parse(r.body); return true; } catch { return false; }
      },
      'no error field':     (r) => {
        try {
          const b = JSON.parse(r.body);
          return !b.error && !b.message?.text?.toLowerCase().includes('error');
        } catch { return false; }
      },
    });

    chatErrors.add(!ok);

    if (!ok && __ENV.VERBOSE === '1') {
      console.log(`[VU ${__VU}] chat failed — status=${res.status} body=${res.body?.slice(0, 200)}`);
    }
  });

  // Think time: 0.5–2 s between requests (simulates typing and reading)
  sleep(0.5 + Math.random() * 1.5);
}

// ── Teardown: print summary ───────────────────────────────────────────────────
export function handleSummary(data) {
  const metrics = data.metrics;

  const p50  = metrics.chat_e2e_latency_ms?.values?.['p(50)']?.toFixed(0) ?? 'n/a';
  const p95  = metrics.chat_e2e_latency_ms?.values?.['p(95)']?.toFixed(0) ?? 'n/a';
  const p99  = metrics.chat_e2e_latency_ms?.values?.['p(99)']?.toFixed(0) ?? 'n/a';
  const rps  = metrics.http_reqs?.values?.rate?.toFixed(2) ?? 'n/a';
  const errR = ((metrics.chat_error_rate?.values?.rate ?? 0) * 100).toFixed(2);
  const total = metrics.chat_total_requests?.values?.count ?? 0;

  const summary = [
    '',
    '═══════════════════════════════════════════════════',
    '  UNAgent Chat — Performance Test Summary',
    '═══════════════════════════════════════════════════',
    `  Total chat requests : ${total}`,
    `  Throughput (RPS)    : ${rps}`,
    `  Latency P50         : ${p50} ms`,
    `  Latency P95         : ${p95} ms`,
    `  Latency P99         : ${p99} ms`,
    `  Error rate          : ${errR} %`,
    '═══════════════════════════════════════════════════',
    '',
  ].join('\n');

  return {
    stdout: summary,
    '/results/summary.json': JSON.stringify(data, null, 2),
  };
}
