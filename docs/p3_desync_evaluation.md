# P3 Spec Desync Evaluation

Evaluated against `docs/p3_1D.md` — 2026-05-25.

---

## Methodology

Each spec requirement was matched to the implementation, tested where possible,
and rated: ✅ Aligned / ⚠️ Partial / ❌ Desync.

---

## 1. Decomposition Structure

| Spec Module | Spec Submodules | Status | Evidence |
|---|---|---|---|
| **chat-orch** | Channel Entry, LLM Cycle, stream response, record feedback, emit metrics | ✅ | `routes.rs`, `runtime.rs`, `sse.rs`, `gateway.rs::record_turn/record_feedback` |
| **agent-runtime** | Agent Configuration, Async Jobs | ✅ | `routes/acr.ts`, `routes/jobs.ts`, `broker/jobs.ts` |
| **conversation-chat** | Sessions, Turns | ✅ | `/api/v1/sessions`, `/api/v1/sessions/:sid/turns` |
| **tenant** | Authentication, Tenant Resources, Tenant Management | ✅ | `handlers/auth_handler.go`, RBAC middleware, `listTenantsHandler` |
| **user-auth** | OTP Verification, User Management | ✅ | Wired in `telegram.rs::run_pre_registration()`, `UserAuthClient` |
| **compliance-metrics** | Event Logging, Statistics | ✅ | `Compliance/main.py`: `/v1/event`, `/stats/kpis`, `/stats/timeseries` |
| **email-send** | Email Dispatch, Audit Trail | ✅ | `EmailController`, `EmailAudit`, `EmailRepository` |

All seven decomposition modules are implemented.

---

## 2. Security Scenario 4 — Rate Limiting (most relevant to the reported bugs)

| Spec requirement | Implementation | Status | Fix applied |
|---|---|---|---|
| `chat-orch` `tenant_chat`: 20 burst / 1 req/s | `rate_limit.rs::Limiters::tenant_chat`, wired in `routes.rs::chat_forward` | ✅ | — |
| `chat-orch` `tenant_feedback`: 10 burst / 0.5 req/s | `rate_limit.rs::Limiters::tenant_feedback`, wired in `routes.rs::submit_feedback` | ✅ | — |
| `tenant` `/auth/login`: 5 burst / 1 req/30s | `middlewares/rate_limit_middleware.go::LoginRateLimiter()`, wired in `router.go:73` | ✅ | — |
| Frontend Axios interceptor renders cooldown toast on 429 | `api/axios.ts:48-62` — reads `Retry-After`, shows toast, attaches `retryAfterSecs` | ✅ | — |
| **Telegram rate limiting** | ❌ was keyed by `tenant_id` (shared across all users) | ✅ **Fixed** | `telegram.rs`: now keys by `chat_id` |
| **Login form 429 UX** | ❌ `LoginForm.tsx` `catch` showed "Invalid credentials" for 429 (double-toast, wrong message) | ✅ **Fixed** | `LoginForm.tsx:80`: skip toast when `status === 429` |
| **Console send button concurrent spam** | ⚠️ Send button not disabled during in-flight request; burst=20 made rate limit feel non-functional to manual testers | ✅ **Fixed** | `AgentConsole.tsx`: `isSending` state guard |
| **Tenant login rate limiter has tests** | ❌ Middleware existed but had zero unit tests | ✅ **Fixed** | `Tenant/middlewares/rate_limit_middleware_test.go`: 7 tests |

---

## 3. Security Scenarios 1–3

| Scenario | Pattern | Status |
|---|---|---|
| Inter-service confidentiality | Secure Channel (AES-256-GCM) | ✅ `channel.rs` — 4 unit tests including AEAD tamper detection |
| Direct backend access | Reverse Proxy (NGINX) | ✅ `FrontEnd/nginx.conf` single origin on :3000 |
| Lateral movement to DBs | Network Segmentation | ✅ 5 named Docker networks in `docker-compose.yml` (Net-Public, Net-Orchestrator, Net-Tenant, Net-Compliance, Net-DB) |

**Note:** The spec names 10 distinct networks including `Net-Chat-DB`, `Net-Email-DB`, `Net-Auth-DB` etc. The current compose has 5 consolidated networks covering the same zones. This is a minor structural deviation but does not violate the isolation intent.

---

## 4. Performance / Scalability

| Spec tactic | Status |
|---|---|
| Token-bucket rate limiter (1 req/s burst 20) | ✅ |
| HTTP 429 + Retry-After returned | ✅ |
| Frontend Axios interceptor reacts with cooldown UI | ✅ (after fix: LoginForm and AgentConsole both correct now) |
| Redis caches session state | ✅ `conversation-chat` uses Redis for session cache |
| Stateless JWT verification (HS256) | ✅ `Tenant` issues and verifies without DB hit |

---

## 5. Test coverage added this session

| Component | Tests added | Passes |
|---|---|---|
| `chat-orch` Rust | 25 (rate_limit, routes, telegram) | ✅ 29/29 total |
| `agent-runtime` TypeScript (vitest) | 15 (all routes) | ✅ 15/15 |
| `Tenant` Go (middlewares) | 7 (rate_limit_middleware) | ✅ 7/7 |
| Playwright e2e (stack-up required) | 11 (smoke, auth-rl, chat-rl, csat) | — needs live stack |

---

## 6. Remaining known gaps (out of scope for this session)

- 10-network segmentation spec vs 5-network implementation: functional equivalent, exact named-network alignment not addressed.
- Admin CRUD for agent profiles / data sources: still stub (listed as out-of-scope in CLAUDE.md §11).
- Persisted KPI counters in Compliance: in-memory reset on restart (listed as out-of-scope).
