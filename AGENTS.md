# AGENTS.md — dev-runner

This file is the playbook for AI coding agents (Claude Code, Codex,
Cursor, Aider, etc.) working across the UNAgent platform. Humans are
welcome too. If you're just trying to run the thing, start with
`README.md` — this doc is about *developing* it.

---

## 1. What this repo is

`dev-runner` is the umbrella. Six independent service repos sit under
it as git submodules; this root owns only the glue — `docker-compose.yml`,
`.env.example`, and this doc. One clone + one compose command runs the
full multi-tenant conversational-AI admin platform locally against
hosted Supabase / MongoDB Atlas / OpenRouter.

Everything touching product code lives in the submodule it belongs to.
Commits here should only change: submodule pointers, the compose file,
`.env.example`, `.gitignore`, or this doc.

---

## 2. Stack at a glance

```
           ┌──────────────────────────── frontend  (React 19 / Vite / shadcn)
           │                                │  admin UI, Analytics, Agent Console
           ▼                                │  :3000
  browser ─┤                                │
           │  HTTP (CORS)                   ▼
           ├─────────────▶  tenant     ──▶  Supabase Postgres
           │                :8080           (Session Pooler — IPv4)
           │
           ├─────────────▶  chat-orch  ──┬─▶  hospital-mock (mock data)
           │                :8000         │   :8092
           │    POST /v1/chat             │
           │    GET  /v1/chat/stream      ├─▶  Metricas (counters)
           │    POST /v1/feedback         │   :8091
           │                              │
           │                              └─▶  OpenRouter (LLM, OpenAI-compat)
           │
           └─────────────▶  metricas   ──  (polled every 10 s from Analytics)
                            :8091

  Telegram ──▶  chat-orch (long-poll getUpdates, same runtime as /v1/chat)

  conversation-chat (:8082) is running but currently off the hot path —
  see §6.3.

  Redis (:6379 internal) — conversation-chat sessions.
  Qdrant (:6333) — vector DB slot (satisfies rubric NoSQL requirement).
  MongoDB Atlas — conversation-chat document store.
```

Language mix (per rubric: ≥3 general-purpose languages): **Rust, Go,
Python, TypeScript**.

---

## 3. Submodule map

| Path | Upstream | Language | Role |
|---|---|---|---|
| `chat-orch/` | UNagent-1D/chat-orch | Rust (Axum, Tokio, reqwest) | Front-door orchestrator. Owns the LLM turn loop, hospital tool calling, SSE, Telegram long-poll, metricas tap. |
| `Tenant/` | UNagent-1D/Tenant | Go (Gin, lib/pq, bcrypt) | Auth + tenant admin API. JWT issuance via `/auth/login`. |
| `conversation-chat/` | UNagent-1D/conversation-chat | Go (Gin, mongo-driver, go-redis, go-openai) | Session + history service. Currently bypassed (see §6.3). |
| `Hospital-MP/` | UNagent-1D/Hospital-MP | Python 3.12 (Flask) | Mock scheduling API. Five endpoints per `hospital_mock_api_requirements.docx.md`. |
| `Metricas/` | UNagent-1D/Metricas | Go (Gin, prometheus client) | In-memory KPI counters + daily buckets + CORS + /stats endpoints. |
| `FrontEnd/` | UNagent-1D/FrontEnd | TypeScript (React 19, Vite, Tailwind, shadcn/ui, TanStack Query, recharts, react-hook-form, zod, Zustand) | Admin dashboard. |

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
| `TELEGRAM_DEFAULT_TENANT_ID` | `demo-tenant` | Metricas bucket for Telegram traffic |
| `VITE_ORCH_API_URL` | `http://localhost:8000` | Frontend override |
| `VITE_METRICAS_API_URL` | `http://localhost:8091` | Frontend override |
| `VITE_TENANT_API_URL` | `http://localhost:8080` | Frontend override |
| `VITE_CHAT_API_URL` | `http://localhost:8082/api/v1` | Frontend override |

Per-service env (injected by `docker-compose.yml`):

- chat-orch: `CONVERSATION_CHAT_URL`, `TENANT_SERVICE_URL`,
  `METRICAS_URL`, `HOSPITAL_MOCK_URL`, `OPENAI_BASE_URL`,
  `OPENAI_DEFAULT_MODEL` (default `nvidia/nemotron-3-super-120b-a12b:free`),
  `CORS_ALLOW_ORIGIN`, `RUST_LOG`, `LOG_FORMAT`.
- conversation-chat: `AUTH_STUB=true` (bypasses auth-service validation;
  the `Authorization` header still must be present — any non-empty
  bearer works).
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
  gateway.rs    HTTP clients: ConversationChatClient (unused),
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

Currently **not on the hot path**. It's running in the compose stack
(its `/api/v1/health` is green), but chat-orch no longer forwards to
it. The reason: its `CreateSession` requires live calls to an Agent
Config Registry (ACR) service and additional Tenant endpoints
(`/profiles`, `/data-sources`) that don't exist yet.

When ACR exists, re-enable the path by reverting the runtime delegation
in `chat-orch/src/routes.rs::chat_forward` to call
`state.conversation_chat.create_session/post_turn` instead of
`runtime::run_turn`. The `ConversationChatClient` + AppState wiring is
intact.

### 6.4 Hospital-MP (Python / Flask)

Single-file service (`app.py`), in-memory dicts. Endpoints:

- `GET /doctors` (optional `area`, `place`)
- `GET /doctors/{doctor_id}/schedule` (optional `days_ahead`)
- `POST /appointments`
- `POST /appointments/{appt_id}/cancel`
- `GET /patients/{patient_ref}/appointments`
- `GET /health`

Seed data: 5 doctors (`doc-001` … `doc-005`), 2 pre-booked appointments
for patient `HOSP-PAT-00492`.

Don't persist — on-purpose reset per restart.

### 6.5 Metricas (Go / Gin)

```
main.go
  tenantStats              rolling totals per tenant (already existed)
  daily                    map[tenant_id][YYYY-MM-DD]*dayStats  (new)
  handleChat               POST /conversation/chat  (X-Tenant-ID)
  handleCsat               POST /feedback/csat      (X-Tenant-ID)
  getFrontendMetrics       GET  /stats/kpis         (public)
  getTimeSeries            GET  /stats/timeseries?tenant_id=&days=  (public)
  promhttp.Handler         GET  /metrics
  corsMiddleware           wildcard CORS (reflect origin)
```

In-memory state — counters reset on restart. `demo-tenant` is the
default Telegram/web bucket. CSAT persists in today's bucket AND in the
rolling tenantStats.

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

---

## 7. Data stores

| Store | Location | Purpose | Persistence |
|---|---|---|---|
| Postgres | Supabase (hosted) | Tenant auth DB — `tenants`, `users`, `user_tenants` | ✓ |
| MongoDB | Atlas (hosted) | conversation-chat sessions + turn history | ✓ |
| Redis | docker-compose | conversation-chat session cache | only compose volume |
| Qdrant | docker-compose | vector DB slot (rubric) | `qdrant-data` volume |
| in-memory | chat-orch | SessionStore (per-process) | ❌ reset on restart |
| in-memory | Metricas | tenantStats + daily buckets | ❌ reset on restart |

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
| Dashboard KPI cards empty on login | Metricas missing CORS headers. Rebuild metricas. Also: counters reset on every metricas restart — drive some traffic. |
| Telegram bot silent | Check `TELEGRAM_BOT_TOKEN` + `TELEGRAM_DEFAULT_TENANT_ID` in `.env`; ensure no webhook is set (`getWebhookInfo.url == ""`); recreate container to pick up env changes. |
| Port 8090/6379/3000 "already allocated" | Another docker project on your machine. Host port collisions — edit the left-hand port in `docker-compose.yml`. |
| chat-orch gets 401 from conversation-chat | `AUTH_STUB=true` still requires a Bearer header. chat-orch sends `Bearer internal`; don't strip it. (Moot today — orch no longer forwards there.) |
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

- **ACR (Agent Config Registry).** Would enable conversation-chat's
  session flow. When it lands, revert the chat-orch routes to
  delegate session + turn creation to conversation-chat.
- **Admin CRUD for agent profiles, data sources, tool registry.** Schema
  sketched in an earlier plan; no endpoints written. Frontend pages
  still show mock data.
- **Operator flows** (escalation queue, active chat, customer lookup).
  Pages currently render "Coming soon" stubs.
- **Persisted Metricas state.** Currently in-memory; a restart clears
  the dashboard.
- **History persistence in chat-orch.** `SessionStore` is a
  `HashMap<String, Vec<ChatMessage>>`; nothing survives a restart.
- **Voice channel** (P2-P3 per the original rubric). Not on any
  current branch.

---

## 12. Who owns what

| Area | Primary author |
|---|---|
| chat-orch (Rust orchestrator) | Loaiza (@juanloaiza21) |
| Tenant (Go auth + admin) | Victor, Nicolás (@nizuga), Manuel (@ManuelEDS) |
| conversation-chat (Go sessions) | Daniel |
| FrontEnd (React dashboard) | Manuel, Julian |
| Hospital-MP (Python mock) | shared |
| Metricas (Go KPIs) | shared |

If you're an AI and you're about to change something cross-cutting,
make sure one of the humans above gets tagged on review.

---

## 13. License

Individual sub-repos carry their own licenses (mostly MIT). This
umbrella inherits nothing beyond the submodule pointers it holds.
