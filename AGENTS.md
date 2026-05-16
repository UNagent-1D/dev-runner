# AGENTS.md — dev-runner

This file is the playbook for AI coding agents (Claude Code, Codex,
Cursor, Aider, etc.) working across the UNAgent platform. Humans are
welcome too. If you're just trying to run the thing, start with
`README.md` — this doc is about *developing* it.

---

## 1. What this repo is

`dev-runner` is the umbrella. Seven independent service repos sit under
it as git submodules; this root owns only the glue — `docker-compose.yml`,
`.env.example`, and this doc. One clone + one compose command runs the
full multi-tenant conversational-AI admin platform locally against
hosted Supabase / MongoDB Atlas / OpenRouter.

Everything touching product code lives in the submodule it belongs to.
Commits here should only change: submodule pointers, the compose file,
`.env.example`, `.gitignore`, or this doc.

---

## 2. Stack at a glance

Browser traffic is single-origin: the frontend container's nginx
(`FrontEnd/nginx.conf`) serves the SPA *and* reverse-proxies every API
path to the right backend over the internal Docker network. The browser
only ever talks to `http://localhost:3000`. Backends still expose host
ports (8000/8080/8082/8091/...) so devs can `curl` them directly — the
proxy is additive.

```
           ┌──────────────────────────── frontend  nginx  (SPA + reverse proxy)
           │                                │  :3000  ── /v1/*       → chat-orch
           ▼                                │         ── /auth/*     → tenant
  browser ─┤  HTTP (same-origin)            │         ── /api/admin/ → tenant
           │                                │         ── /api/v1/tenants/ → tenant
           │                                │         ── /api/v1/sessions/ → conversation-chat
           │                                │         ── /stats/*   → compliance
           │                                ▼
           │  (internal Docker network)
           ├─────────────▶  tenant     ──▶  Supabase Postgres
           │                :8080           (Session Pooler — IPv4)
           │
           ├─────────────▶  chat-orch  ──┬─▶  hospital-mock (mock data)
           │                :8000         │   :8092
           │    POST /v1/chat             │
           │    GET  /v1/chat/stream      ├─▶  Compliance (counters + audit)
           │    POST /v1/feedback         │   :8091
           │                              │
           │                              ├─▶  OpenRouter (LLM, OpenAI-compat)
           │                              │
           │                              └─▶  agent-runtime  (:3100)
           │                                        │  ACR stub + tenant stub
           │                                        │  + session proxy
           │                                        ▼
           │                                  conversation-chat (:8082)
           │                                  sessions + history (Mongo/Redis)
           │
           └─────────────▶  compliance ──  (polled every 10 s from Analytics)
                            :8091

  Telegram ──▶  chat-orch (long-poll getUpdates, same runtime as /v1/chat)

  Redis (:6379 internal)            — conversation-chat session cache.
  RabbitMQ (:5672, mgmt :15672)     — async chat_requests / chat_results queues
                                      consumed by conversation-chat::worker and
                                      agent-runtime::broker.
  hospital-postgres (:5432 internal) — backing store for Hospital-MP.
  email-mongo (:27017 internal)     — backing store for email-send + compliance audit log.
```

Language mix (per rubric: ≥3 general-purpose languages): **Rust, Go,
Python, TypeScript, Java**.

---

## 3. Submodule map

| Path | Upstream | Language | Role |
|---|---|---|---|
| `chat-orch/` | UNagent-1D/chat-orch | Rust (Axum, Tokio, reqwest) | Front-door orchestrator. Owns the LLM turn loop, hospital tool calling, SSE, Telegram long-poll, metricas tap. |
| `Tenant/` | UNagent-1D/Tenant | Go (Gin, lib/pq, bcrypt) | Auth + tenant admin API. JWT issuance via `/auth/login`. |
| `conversation-chat/` | UNagent-1D/conversation-chat | Go (Gin, mongo-driver, go-redis, go-openai) | Session + history service. Wired via agent-runtime (see §6.3). |
| `agent-runtime/` | UNagent-1D/agent-runtime | TypeScript (Express 5, Node.js) | ACR stub + tenant stub + session proxy. Bridges chat-orch → conversation-chat. |
| `Hospital-MP/` | UNagent-1D/Hospital-MP | Python 3.12 (Flask) | Mock scheduling API. Five endpoints per `hospital_mock_api_requirements.docx.md`. |
| `Compliance/` | (in-tree, not a submodule) | Python 3.12 (FastAPI, motor) | KPI counters + daily buckets + audit-log writer (Mongo). Back-compat with the old Metricas wire contract. |
| `FrontEnd/` | UNagent-1D/FrontEnd | TypeScript (React 19, Vite, Tailwind, shadcn/ui, TanStack Query, recharts, react-hook-form, zod, Zustand) | Admin dashboard. |
| `UN_email_send_ms/` | UNagent-1D/UN_email_send_ms | Java 21 (Spring Boot 3.3.x, Spring Data MongoDB, sendgrid-java, jjwt) | Outbound-email dispatch + audit trail. Sends via SendGrid, persists every attempt to a dedicated local Mongo (`email_events`). |

Every submodule tracks `branch = main` in `.gitmodules`. The umbrella
pins a specific commit; `git submodule update --remote --merge` bumps
to the tip of each tracked branch.

---

## 4. End-to-end request flows

### 4.1 Web chat (Agent Console → bot reply)

```
1. Browser  POST /v1/chat             → chat-orch
             { tenant_id, session_id?, message }
2. chat-orch emits metricas.record_turn(resolved=false) (fire-and-forget)
3. chat-orch run_turn():
   a. append user msg to in-memory SessionStore
   b. call OpenRouter with tools=hospital_tool_definitions()
   c. if tool_calls: execute via HospitalClient, feed tool results back, loop (≤5 rounds)
   d. on book_appointment success → resolved=true
4. chat-orch publishes { kind:"assistant", text } to SseHub(session_id)
5. chat-orch emits metricas.record_turn(resolved=true) if booked
6. Browser (EventSource on /v1/chat/stream?session_id=…) receives the
   assistant event and renders a bubble.
```

### 4.2 Telegram chat

Identical to 4.1 except the ingress is a `getUpdates` long-poll inside
`chat-orch/src/telegram.rs` and the egress is `sendMessage` back to
Telegram. Uses `TELEGRAM_DEFAULT_TENANT_ID` for the metricas tenant.
Per-chat `chat_id → session_id` map is in-memory.

### 4.3 Auth

```
POST /auth/login  (Tenant) → JWT (HS256, issuer=tenant-service)
                           claims: user_id, email, tenant_id, role, exp
Frontend stores in Zustand authStore; attaches Authorization: Bearer
on subsequent calls. All non-public Tenant routes require that header
(the AuthStub middleware in conversation-chat checks presence too).
```

### 4.4 Analytics

```
Frontend Analytics page   → GET /stats/kpis      (cards)
                          → GET /stats/timeseries (chart)
                              ?tenant_id=<id>&days=7
CSAT submit in Console    → POST /v1/feedback   (chat-orch)
                             ↳ chat-orch forwards → POST /feedback/csat (metricas)
```

Refetch is `refetchInterval: 10_000` in TanStack Query.

---

## 5. Environment variables (root `.env`)

Required:

| Var | Source | Used by |
|---|---|---|
| `OPENROUTER_API_KEY` | https://openrouter.ai/keys | chat-orch, conversation-chat (as `OPENAI_API_KEY`) |
| `JWT_SECRET` | your choice (long random) | Tenant (issuer) |
| `DATABASE_URL` | Supabase → Connect → Session Pooler | Tenant |
| `MONGO_URI` | Mongo Atlas → Connect → Drivers | conversation-chat |
| `MONGO_DB` | `conversatory` default | conversation-chat |

Optional:

| Var | Default | Role |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | unset | Enables Telegram ingress (BotFather) |
| `TELEGRAM_DEFAULT_TENANT_ID` | `demo-tenant` | Compliance/metrics bucket for Telegram traffic |
| `MONGO_URI_COMPLIANCE` | `mongodb://email-mongo:27017` | Compliance — where the audit collection is written. Override to use Atlas or another host. |
| `MONGO_DB_COMPLIANCE` | `UN_compliance_db` | Compliance — DB name for the `audit_logs` collection |
| `VITE_ORCH_API_URL` | `` (empty — same-origin via nginx) | Frontend override; set only when the bundle must call a different origin |
| `VITE_METRICAS_API_URL` | `` (empty — same-origin via nginx) | Frontend override (still named METRICAS for back-compat — points at Compliance now) |
| `VITE_TENANT_API_URL` | `` (empty — same-origin via nginx) | Frontend override |
| `VITE_CHAT_API_URL` | `/api/v1` (same-origin via nginx) | Frontend override |
| `SENDGRID_API_KEY` | unset | UN_email_send_ms — required if you actually want delivery; in sandbox it is unused but the env var still has to exist |
| `SENDGRID_SANDBOX_MODE` | `true` | UN_email_send_ms — when true, SendGrid accepts the request and returns 202 without delivering |
| `EMAIL_FROM_DEFAULT` | `noreply@unagent.local` | UN_email_send_ms — sender address used when the request omits `from` |
| `EMAIL_FROM_NAME` | `UNAgent Notifications` | UN_email_send_ms — display name |
| `MONGO_DB_EMAIL` | `email_audit` | UN_email_send_ms — DB name on the **local** `email-mongo` container (not Atlas) |
| `EMAIL_AUTH_STUB` | `true` | UN_email_send_ms — when true, any non-empty bearer is accepted |

Per-service env (injected by `docker-compose.yml`):

- chat-orch: `CONVERSATION_CHAT_URL`, `TENANT_SERVICE_URL`,
  `METRICAS_URL`, `HOSPITAL_MOCK_URL`, `OPENAI_BASE_URL`,
  `OPENAI_DEFAULT_MODEL` (default `nvidia/nemotron-3-super-120b-a12b:free`),
  `AGENT_RUNTIME_URL` (`http://agent-runtime:3100`),
  `CORS_ALLOW_ORIGIN`, `RUST_LOG`, `LOG_FORMAT`.
- agent-runtime: `PORT` (default `3100`), `CONVERSATION_CHAT_URL`
  (`http://conversation-chat:8082`), `HOSPITAL_MOCK_URL`
  (`http://hospital-mock:8080`), `OPENAI_DEFAULT_MODEL`.
- conversation-chat: `ACR_SERVICE_URL` + `TENANT_SERVICE_URL` both
  point to `http://agent-runtime:3100`. `AUTH_STUB=true` (bypasses
  auth-service validation; the `Authorization` header still must be
  present — any non-empty bearer works).
- Tenant: reads `DATABASE_URL` + `JWT_SECRET`.

Never commit `.env`. `.gitignore` already excludes it.

---

## 6. Service cheat sheets

### 6.1 chat-orch (Rust / Axum)

```
src/
  main.rs       bootstrap: tracing, reqwest client, SseHub, spawn Telegram
  lib.rs        module exports + AppState
  config.rs     AppConfig::from_env, all env vars in one place
  error.rs      AppError enum, IntoResponse
  gateway.rs    HTTP clients: ConversationChatClient (proxied via agent-runtime),
                MetricasClient (record_turn, record_feedback),
                TelegramClient (get_updates, send_message)
  llm.rs        OpenAI-compatible chat completions with tool calling
  hospital.rs   HospitalClient + tool_definitions() for the 5 ops
  session.rs    SessionStore: in-memory Vec<ChatMessage> per sid
  runtime.rs    run_turn(): system prompt, tool loop, resolved bubble
  routes.rs     /health, /v1/chat, /v1/chat/stream, /v1/feedback, CORS
  sse.rs        SseHub (broadcast per session_id)
  telegram.rs   long-poll loop, chat_id → sid map
```

**Common tasks:**

- **Add a new hospital tool:**
  1. Implement the HTTP call in `hospital.rs::HospitalClient`.
  2. Add a branch in `HospitalClient::call_tool` matching the tool name.
  3. Add the OpenAI-style definition (name/description/parameters) to
     `tool_definitions()`. No other changes — the LLM will pick it up
     on the next turn.

- **Add a new orch endpoint:** add a handler in `routes.rs`, register
  it in `build_router`. CORS layer is already attached.

- **Change the system prompt / persona:** `runtime.rs::SYSTEM_PROMPT`.

- **Increase tool-call rounds:** `runtime.rs::MAX_TOOL_ROUNDS` (default 5).

- **Rebuild just chat-orch:**
  ```
  docker compose up -d --build chat-orch
  ```

**Gotchas:**

- `Cargo.toml` specifies `rust-version = "1.75"` but some transitive
  deps need 1.88+. The Dockerfile pins `rust:1.88-slim`; don't downgrade.
- The `[[bench]]` in earlier versions pointed at a nonexistent bench
  file and blocked `cargo build`. Check before re-adding benches.

### 6.2 Tenant (Go / Gin)

```
main.go                     DB init + router.Run(":8080")
router.go                   all route wiring + CORS middleware +
                            listTenantsHandler
config/database.go          sql.Open via DATABASE_URL
handlers/auth_handler.go    LoginHandler (bcrypt + JWT HS256)
middlewares/rbac_middleware.go   AuthMiddleware + RoleMiddleware
models/auth_models.go       User, UserTenant, Claims
sql/init_schema.sql         tenants, users, user_tenants + check-constraint
```

**Common tasks:**

- **Add a new admin endpoint:** write the handler under `handlers/`,
  register in `router.go` inside `adminGroup` (app_admin only) or
  `tenantGroup` (tenant_admin/operator). Read caller claims from the
  gin context (keys in `middlewares/rbac_middleware.go`).

- **Seed users:** use the bcrypt hash via pgcrypto in SQL (see README
  quickstart block) — matches Go's `bcrypt.CompareHashAndPassword`.

**Gotchas:**

- `check_role_tenant_logic` on `user_tenants` requires `app_admin` to
  have `tenant_id = NULL`; tenant_* must have a non-null tenant_id.
- Every bearer Gate including stub mode needs `Authorization: Bearer …`
  present — empty header → 401 even with `AUTH_STUB=true`.

### 6.3 conversation-chat (Go / Gin)

Now wired into the stack via **agent-runtime**. chat-orch sends session
and turn requests to agent-runtime, which adapts the payload shape and
proxies them to conversation-chat. conversation-chat's `ACR_SERVICE_URL`
and `TENANT_SERVICE_URL` both resolve to agent-runtime, which stubs
those dependencies.

The `ConversationChatClient` path inside chat-orch is activated by
`AGENT_RUNTIME_URL` pointing at agent-runtime rather than directly at
conversation-chat — agent-runtime normalises the request shape
(`OpenSessionRequest` / `TurnRequest`) before forwarding.

If the path breaks, check: (1) agent-runtime is up (`/health`),
(2) `AUTH_STUB=true` is set and any Bearer token is present in forwarded
headers, (3) Mongo and Redis are healthy (conversation-chat depends on
both).

### 6.4 Hospital-MP (Python / Flask)

`app.py` plus a thin DB layer in `db.py` (`LocalDBClient` over psycopg2,
chain API matching supabase-py so the same code runs against either backend).
Schema is in `schema.sql`; static seed in `seed.sql` (Python `seed.py` is
the Supabase-only equivalent, used when `DATABASE_URL` is absent).

Endpoints:

- `GET /doctors` (optional `area`, `place`)
- `GET /doctors/{doctor_id}/schedule` (optional `days_ahead`)
- `POST /appointments`
- `POST /appointments/{appt_id}/cancel`
- `GET /patients/{patient_ref}/appointments`
- `GET /health`

Seed data: 5 doctors (`doc-001` … `doc-005`), 2 pre-booked appointments
for patient `HOSP-PAT-00492`.

Persistence: backed by the `hospital-postgres` compose service. Schema
and seed are auto-applied on the first boot of the volume via Postgres'
`/docker-entrypoint-initdb.d` convention. To re-seed, drop the
`hospital-postgres-data` volume and recreate the container.

**Common tasks:**

- **Add a new doctor or pre-booked appointment:** edit `Hospital-MP/seed.sql`
  and recycle the volume (`docker compose down -v hospital-postgres &&
  docker compose up -d hospital-postgres`).
- **Add a new column:** add it to `schema.sql`, then either drop the
  volume to re-apply, or write a migration step into a new
  `Hospital-MP/migrations/NNN_*.sql` and update the Dockerfile/compose
  init mount accordingly.

### 6.5 Compliance (Python / FastAPI)

In-tree at `Compliance/` (not a submodule). Replaces the old Go Metricas
service while keeping its wire contract intact, so `chat-orch::MetricasClient`
and the FrontEnd Analytics page need no change.

```
Compliance/
  main.py
    tenant_stats               rolling totals per tenant (in-memory)
    daily                      tenant_id → YYYY-MM-DD → DayBucket
    legacy_chat                POST /conversation/chat  (X-Tenant-ID)        ← chat-orch.record_turn
    legacy_csat                POST /feedback/csat      (X-Tenant-ID)        ← chat-orch.record_feedback
    get_kpis                   GET  /stats/kpis                              ← FrontEnd Analytics
    get_timeseries             GET  /stats/timeseries?tenant_id=&days=       ← FrontEnd Analytics
    submit_feedback_v1         POST /v1/feedback                              (new)
    register_event             POST /v1/event                                 (new — writes to Mongo audit_logs)
    health                     GET  /health
    CORSMiddleware             wildcard, allow X-Tenant-ID
  requirements.txt             fastapi / uvicorn / motor / pydantic / dotenv
  Dockerfile                   python:3.12-slim, listens on :8091
```

Counters are in-memory (reset on restart). The audit log is persisted to
the local `email-mongo` container by default (`MONGO_URI_COMPLIANCE`,
DB `UN_compliance_db`, collection `audit_logs`).

### 6.6 FrontEnd (React / Vite / shadcn)

```
src/
  App.tsx                          router, RoleGuard per route
  main.tsx                         QueryClient, ThemeProvider, Toaster
  api/
    axios.ts                       4 axios clients: tenantClient, chatClient,
                                   orchClient, metricasClient
    apiService.ts                  HTTP fns grouped by backing service
  store/
    authStore.ts                   Zustand (token + user); memory-only
    tenantStore.ts                 currentTenant
  components/
    layout/                        DashboardLayout (sidebar+header), RoleGuard,
                                   RootRedirect, PageHeader, EmptyState,
                                   ErrorBoundary
    ui/                            shadcn primitives (avatar, badge, card,
                                   skeleton, table, tooltip, sheet, …)
    providers/                     ThemeProvider
  features/
    analytics/                     KpiCard, ConversationsChart, DateRangePicker,
                                   AnalyticsDashboard (10-s refetch, skeletons)
    auth/Login.tsx                 two-column hero + eye-toggle password
    console/AgentConsole.tsx       real POST + EventSource + CSAT widget
    profiles/DashboardProfiles.tsx (still uses mock tools; ACR pending)
    datasources/                   (mock)
    tenants/GlobalTenants.tsx      table + inline create form
    operator/ + lookup/            Coming-soon empty states
  hooks/
    useDarkMode, use-toast, useOperatorSocket (socket.io wrapper, unused)
  lib/
    user.ts (getDisplayName, getInitials)
    palette.ts (roleBadgeVariant, roleLabel)
    utils.ts (cn)
```

**Common tasks:**

- **Add a new page:** create under `features/<name>/`, add the route in
  `App.tsx` wrapped in `<DashboardLayout>`, plus `<RoleGuard>` if
  restricted.
- **New API call:** add to `apiService.ts` using the right client.
  Never call axios directly from components.
- **Change brand palette:** edit CSS vars in `src/index.css` (both
  `:root` and `.dark` blocks).
- **Dev server:** `cd FrontEnd && npm run dev` — hot reload against the
  running backend containers.

**Gotchas:**

- Zustand `authStore` is NOT persisted; refreshing the tab logs you out.
- `tenant_id` on `app_admin` user comes back as `''` (empty string);
  analytics falls back to aggregated view when it's empty.
- Every `VITE_*` var is baked at build time (Vite does static
  replacement). Don't expect runtime env injection beyond the tiny
  `entrypoint.sh` shim.

### 6.7 agent-runtime (TypeScript / Express 5)

```
src/
  index.ts              bootstrap: Express app, mount all routers, listen
  registry.ts           in-memory AgentProfile store; currently always
                        resolves to hospitalProfile regardless of id
  agents/
    hospital.ts         hospitalProfile: system prompt (es-CO), 5 tools,
                        modelConfig, escalation, allowedSpecialties/Locations
  routes/
    acr.ts              GET /api/v1/tenants/:tid/profiles/:pid/configs/active
                        → ACRConfig (consumed by conversation-chat's ACRClient)
    tenant-stub.ts      GET /api/v1/tenants/:tid
                        GET /api/v1/tenants/:tid/profiles
                        GET /api/v1/tenants/:tid/data-sources
                        (stubs conversation-chat's TenantClient calls)
    proxy.ts            POST /api/v1/sessions
                        POST /api/v1/sessions/:sid/turns
                        (adapts chat-orch thin payloads → conversation-chat
                        OpenSessionRequest / TurnRequest shapes)
    health.ts           GET /health
  types/
    acr.ts, agent.ts, tenant.ts   shared interfaces
```

**Common tasks:**

- **Add or change the agent persona / tools:** edit `agents/hospital.ts`.
  The system prompt, tool definitions, and model config all live there.
  `registry.ts` will pick up the change on next restart (no other wiring
  needed while there is only one profile).

- **Add a second agent profile:**
  1. Create `agents/<name>.ts` following the `AgentProfile` shape.
  2. Import and add to the `profiles` Map in `registry.ts`.
  3. Update `getProfile()` to do a real `profiles.get(id)` lookup with a
     fallback instead of always returning `hospitalProfile`.

- **Add a new data-source tool route:** add an entry to `route_configs`
  in `tenant-stub.ts::DataSource`. conversation-chat's `executeTool()`
  will automatically use the new route via `{param}` substitution.

- **Rebuild just agent-runtime:**
  ```
  docker compose up -d --build agent-runtime
  ```

**Gotchas:**

- `registry.ts::getProfile()` ignores the requested `id` and always
  returns `hospitalProfile`. This is intentional while there is only one
  profile, but must change before multi-tenant profiles can diverge.
- The proxy uses the native `fetch` API (Node 18+). The Dockerfile must
  use Node ≥18; check before downgrading the base image.
- `OPENAI_DEFAULT_MODEL` in the agent-runtime container overrides the
  model baked into `hospitalProfile.modelConfig.model`. The compose file
  sets it; ACR responses reflect the env value, not the code default.

### 6.8 UN_email_send_ms (Java / Spring Boot)

```
src/main/java/co/edu/unagent/emailsend/
  EmailSendApplication.java   bootstrap (@SpringBootApplication)
  api/
    EmailController.java       POST /api/v1/emails, GET single, GET list
    HealthController.java      /health (Mongo ping with 1s deadline)
    ErrorEnvelope.java         { error, request_id }
    dto/                       SendEmailRequest, SendEmailResponse,
                               EmailAuditDto, PageResponse
  domain/
    EmailAudit.java            @Document("email_events")
    EmailStatus.java           QUEUED / SENT / FAILED
    EmailRepository.java       MongoRepository + idempotency lookup
  service/
    EmailService.java          orchestrator (validate → audit → send → update)
    EmailProvider.java         interface for tests
    SendGridEmailProvider.java Web API v3, retry once on 5xx/IOException
  security/
    JwtAuthFilter.java         HS256 verify, populates SecurityContext
    AuthStubFilter.java        active when AUTH_STUB=true
    SecurityConfig.java        filter chain wiring + permitAll(/health)
  config/
    AppProperties.java         @ConfigurationProperties + @NotBlank
    SendGridConfig.java        SendGrid bean
    MongoIndexInitializer.java idempotent index creation on startup
    MongoStartupPing.java      @PostConstruct ping (fail-fast)
  error/GlobalExceptionHandler.java   ControllerAdvice → ErrorEnvelope
  observability/RequestIdFilter.java  X-Request-Id + MDC
```

**Common tasks:**

- **Add a new email category:** no code change. The caller passes
  `category: "your.tag"` in the request body and it lands on the audit row.

- **Switch sender provider:** implement `EmailProvider` (e.g.
  `SesEmailProvider`) and replace the `@Component` annotation on
  `SendGridEmailProvider`. The audit flow in `EmailService` is provider-agnostic.

- **Inspect the audit collection:**
  ```
  docker compose exec email-mongo mongosh email_audit \
    --eval 'db.email_events.find().sort({created_at:-1}).limit(5).pretty()'
  ```

- **Rebuild just email-send:**
  ```
  docker compose up -d --build email-send
  ```

**Gotchas:**

- The audit collection lives on the **local** `email-mongo` container,
  not Atlas. The umbrella sets `MONGO_URI: "mongodb://email-mongo:27017"`
  for this service explicitly so it never reuses the Atlas URI that
  conversation-chat consumes.
- `SENDGRID_SANDBOX_MODE=true` (default) makes SendGrid return 202
  without delivering. Audit rows still get `status=SENT` because
  SendGrid considered the request accepted; that is the intended
  semantics for sandbox testing.
- Spring Boot bakes `SERVER_PORT` at boot from the env var; the
  container always listens on 8080 internally and is host-mapped to
  8089 by compose.
- Required env vars (`SENDGRID_API_KEY`, `MONGO_URI`, `JWT_SECRET`,
  `EMAIL_FROM_DEFAULT`) are validated by `@NotBlank`; the container
  refuses to start if any is empty.

---

## 7. Data stores

In **production on Railway** all six stateful pieces are self-hosted Railway services (one per environment) with attached volumes — no external SaaS. In **local dev** the same images run inside `docker-compose.yml`. The `.env.dev` / `.env.prod` files in the umbrella point at Railway-internal hostnames; the local `.env` points at the compose service names.

| Store | Local (compose) | Prod / dev (Railway) | Purpose |
|---|---|---|---|
| Postgres | `tenant-postgres` (or Supabase if you kept the legacy `.env`) | `tenant-postgres` Railway service (`postgres:16-alpine` + `Tenant/sql/init_schema.sql`) | Tenant auth DB — `tenants`, `users`, `user_tenants` |
| MongoDB | conversation-chat → Atlas (legacy `.env`) | `conversation-mongo` Railway service (`mongo:7`) | conversation-chat sessions + turn history |
| MongoDB | `email-mongo` | `email-mongo` Railway service (`mongo:7`) | UN_email_send_ms `email_audit.email_events`; Compliance `UN_compliance_db.audit_logs` |
| Postgres | `hospital-postgres` | `hospital-postgres` Railway service (`postgres:16-alpine` + `Hospital-MP/{schema,seed}.sql`) | Hospital-MP doctors + appointments |
| Redis | `redis` | `redis` Railway service (`redis:7-alpine`) | conversation-chat session cache |
| RabbitMQ | `rabbitmq` (from `UN_message_broker_mb`) | `rabbitmq` Railway service (same custom image) | chat_requests / chat_results queues for the async worker path |
| in-memory | chat-orch | chat-orch | SessionStore (per-process) — ❌ reset on restart |
| in-memory | Compliance | Compliance | tenantStats + daily buckets — ❌ reset on restart |

Init scripts for `tenant-postgres` and `hospital-postgres` are baked into custom Dockerfiles at `scripts/data-stores/`. Postgres applies them once against an empty volume on first boot. Re-seed by deleting the Railway volume (or, locally, by dropping the compose volume).

---

## 8. Common tasks at the umbrella level

- **Bump all submodules to latest upstream `main`:**
  ```
  git submodule update --remote --merge
  git add . && git commit -m "chore: bump submodules" && git push
  ```

- **Pin a submodule to a specific commit (rollback / freeze):**
  ```
  cd <submodule>
  git checkout <sha>
  cd ..
  git add <submodule>
  git commit -m "chore(<name>): pin to <sha>"
  ```

- **Fresh rebuild of one service:**
  ```
  docker compose up -d --build <service>
  ```

- **Full stop + clean start:**
  ```
  docker compose down
  docker compose up --build -d
  ```

- **Follow logs of one service:**
  ```
  docker compose logs -f chat-orch
  ```

---

## 9. Troubleshooting

| Symptom | Likely cause |
|---|---|
| `tenant` exits with `network is unreachable: 2600:…:5432` | `DATABASE_URL` points at Supabase **direct** URL (IPv6-only on free tier). Switch to the **Session Pooler** URI. |
| Browser login says "Invalid credentials" but `curl POST /auth/login` works | CORS preflight failing. Verify `Tenant/router.go::corsMiddleware` is in place and Tenant was rebuilt after changes. |
| `/api/admin/tenants` white-screens the page | Tenant returning `{message:"..."}` instead of an array. Check `listTenantsHandler` is wired. |
| Dashboard KPI cards empty on login | Compliance returned an empty `data` array. Counters reset on every compliance restart — drive some traffic. CORS is enabled by default in `Compliance/main.py`. |
| Telegram bot silent | Check `TELEGRAM_BOT_TOKEN` + `TELEGRAM_DEFAULT_TENANT_ID` in `.env`; ensure no webhook is set (`getWebhookInfo.url == ""`); recreate container to pick up env changes. |
| Port 8090/6379/3000 "already allocated" | Another docker project on your machine. Host port collisions — edit the left-hand port in `docker-compose.yml`. |
| chat-orch gets 401 from conversation-chat | `AUTH_STUB=true` still requires a Bearer header. agent-runtime proxy forwards `Authorization: Bearer internal`; don't strip it. |
| conversation-chat exits on startup | Likely Atlas (`MONGO_URI`), Redis, or RabbitMQ not reachable. Check `depends_on` health conditions; run `docker compose logs redis rabbitmq`. Atlas issues won't show local logs — verify the SRV URI from outside the container. |
| hospital-mock can't reach the DB | The `hospital-postgres` container hadn't passed `pg_isready` when `hospital-mock` started — the `depends_on: condition: service_healthy` should prevent this, but if you scaled or restarted hospital-mock standalone, recreate it after Postgres is up. |
| agent-runtime returns 502 on `/api/v1/sessions` | conversation-chat is down or not yet healthy. Run `docker compose logs conversation-chat` and verify Mongo/Redis are up first. |
| ACR config returns wrong model | `OPENAI_DEFAULT_MODEL` env var in the agent-runtime container overrides the code default. Check `docker compose config agent-runtime`. |
| frontend docker build `chmod: Operation not permitted` | `USER appuser` must come **after** the `chmod +x entrypoint.sh` step. |
| chat-orch cargo build: "can't find `throughput` bench" | Orphan `[[bench]]` section in `Cargo.toml`. Remove it or add a stub file. |

---

## 10. Conventions

**Commits (all repos):** conventional-ish prefix + imperative subject.
Use scopes where useful: `feat(orch): …`, `fix(tenant): …`,
`chore(frontend): …`, `docs: …`, `refactor(metricas): …`.

**Branches:** `feat/<short-slug>`, `fix/<short-slug>`. Branch off `main`.

**PR titles:** same convention as commit subjects. Keep the body
focused on *why*; leave *what* for the diff.

**Co-authors:** if an AI agent materially contributed, include:
```
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

**Never:** commit `.env`, hardcode real credentials in code, skip
pre-commit hooks, push force to `main`, revoke a teammate's
in-flight PR branch.

---

## 11. Out of scope / follow-ups

Features people ask about that aren't built yet:

- **Real ACR persistence.** agent-runtime ships a working in-memory ACR
  stub (`registry.ts`). It always returns the same `hospitalProfile`
  regardless of the requested profile id. A real ACR would persist
  profiles to a DB, support CRUD, and resolve per-tenant configurations.
- **Admin CRUD for agent profiles, data sources, tool registry.**
  agent-runtime exposes the read side via stub endpoints. Write-side
  endpoints and a connected Frontend UI are not implemented; the
  Profiles and Data Sources pages in the dashboard still show mock data.
- **Operator flows** (escalation queue, active chat, customer lookup).
  Pages currently render "Coming soon" stubs.
- **Persisted KPI state in Compliance.** Counters and daily buckets are
  in-memory; a restart clears the dashboard. Audit logs DO persist to
  Mongo, so the per-event history survives.
- **History persistence in chat-orch.** `SessionStore` is a
  `HashMap<String, Vec<ChatMessage>>`; nothing survives a restart.
- **Voice channel** (Twilio). Env vars (`TWILIO_*`) are wired through
  `chat-orch` in compose so the contract is in place, but no service
  consumes them yet. See `.env.example` for credential layout.

---

## 11.1 Deployment

Local dev: `docker compose up --build -d` is the only blessed path.

Production target: **Railway (Hobby) + Cloudflare**. Every backend and every
data store runs as a Railway service in two environments (`dev`, `prod`).
The FrontEnd ships to a Cloudflare Worker that doubles as the single-origin
gateway (it serves the Vite SPA *and* reverse-proxies API paths to Railway
backends — same routing rules as `FrontEnd/nginx.conf:41-87`).

- **Cloudflare Worker** (`cloudflare-worker/`) — apex `<apex>` → prod env,
  `dev.<apex>` → dev env. TLS is provisioned by Cloudflare; bindings live in
  `wrangler.toml`. The Worker has no nginx; routing is in `src/index.ts`.
- **Railway** hosts 8 application services + 6 self-hosted data stores
  (Redis, hospital-postgres, email-mongo, RabbitMQ, tenant-postgres,
  conversation-mongo). The data stores have Railway volumes and replace
  the previous Supabase + Atlas dependencies entirely.
- **Single source of truth** for config: `.env.dev` / `.env.prod` in the
  umbrella (gitignored). The bootstrap uploads them as Railway shared
  variables; services reference keys via `${{ shared.KEY }}`.
- **CI/CD:** `.github/workflows/{deploy-dev,deploy-prod,pr-gate}.yml`.
  Push to `dev` → deploy dev. PR `dev → main` only (enforced by
  `pr-gate.yml`); prod won't deploy unless the same SHA has a green
  deploy-dev run.

First-time setup is one command: `scripts/bootstrap.sh`. The companion doc
`scripts/bootstrap.md` lists the three human checklists (env files, GitHub
secrets, Cloudflare zone). After that, every change ships via `git push`.

The earlier Oracle Cloud + Cloudflare Pages plan is retired — Railway
Hobby covers the resources comfortably and removes the OCI / cloudflared
moving parts.

---

## 12. Who owns what

| Area | Primary author |
|---|---|
| chat-orch (Rust orchestrator) | Loaiza (@juanloaiza21) |
| Tenant (Go auth + admin) | Victor, Nicolás (@nizuga), Manuel (@ManuelEDS) |
| conversation-chat (Go sessions) | Daniel |
| agent-runtime (TS ACR + proxy) | Daniel |
| FrontEnd (React dashboard) | Manuel, Julian |
| Hospital-MP (Python mock) | shared |
| Compliance (Python KPIs + audit) | Vick (@VickDiazr) |

If you're an AI and you're about to change something cross-cutting,
make sure one of the humans above gets tagged on review.

---

## 13. License

Individual sub-repos carry their own licenses (mostly MIT). This
umbrella inherits nothing beyond the submodule pointers it holds.
