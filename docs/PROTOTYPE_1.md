# Prototype 1 — Simple Architectural Structure

**Software Architecture — 2026-I**
**Universidad Nacional de Colombia**

---

## 1. Team

**Team Name:** `1D`

**Members:**

- **Juan David Loaiza Reyes** — General Orchestrator (`chat-orch`, Rust)
- **Víctor Daniel Díaz Reyes** — Tenant Service (Go)
- **Nicolás Zuluaga Galindo** — Tenant Service (Go)
- **Manuel Eduardo Díaz Sabogal** — Tenant Service & Frontend (Go / TypeScript)
- **Daniel Libardo Díaz Gonzales** — Conversation / Chat (Go) & Agent Runtime (TypeScript)
- **Julián Andrés Vaquiro Moreno** — Frontend (TypeScript)

*(Hospital-MP and Metricas are shared work between members.)*

**GitHub organization (source of truth for all repositories):**
<https://github.com/UNagent-1D>

| Repo | Upstream URL |
|---|---|
| Umbrella (deployment) | <https://github.com/UNagent-1D/dev-runner> |
| `chat-orch` | <https://github.com/UNagent-1D/chat-orch> |
| `Tenant` | <https://github.com/UNagent-1D/Tenant> |
| `conversation-chat` | <https://github.com/UNagent-1D/conversation-chat> |
| `agent-runtime` | <https://github.com/UNagent-1D/agent-runtime> |
| `Hospital-MP` | <https://github.com/UNagent-1D/Hospital-MP> |
| `Metricas` | <https://github.com/UNagent-1D/Metricas> |
| `FrontEnd` | <https://github.com/UNagent-1D/FrontEnd> |

---

## 2. Software System

### 2.1. Name

**Un Agent — *Asesores en Salud*** — multi-tenant conversational-AI
administration platform, first vertical slice specialised for hospital
appointment scheduling.

### 2.2. Logo

![Un Agent — Asesores en Salud](logo.png)

### 2.3. Description

Un Agent is a multi-tenant conversational-AI platform that lets
different organisations ("tenants") configure and deploy AI agents
tailored to their business domain. The Prototype 1 vertical slice is
specialised for a hospital scheduling domain: end-users (patients)
interact with the agent through a web chat widget or a Telegram bot
to list doctors, check schedules, book appointments, and cancel them.
Tenant administrators access an admin dashboard — shipped in the same
frontend application — that exposes operational KPIs (conversation
volume, resolution rate, CSAT) and tenant/user management tooling.

The system follows a microservices design organised around a single
front-door **Agent Orchestrator** (`chat-orch`). The orchestrator
terminates every inbound channel (web, Telegram), authenticates the
caller against the **Tenant** service, drives the per-turn LLM
workflow through the **Agent Runtime**, persists conversation state
to MongoDB Atlas, and emits telemetry to the internal **Metricas**
service. The **Conversation/Chat** service feeds the streamed LLM
reply from OpenRouter back up the chain. KPI visualisation is
rendered directly inside the React frontend — there is no third-party
dashboard tool.

**Domain:** Customer-service automation — first prototype specialised
to hospital appointment scheduling (Clínica San Ignacio mock).

**Prototype functional scope:**

- End-user chat over the web (REST + SSE) and Telegram (HTTPS long-poll).
- Tool-calling loop driven by the Agent Runtime against the Hospital
  Mock API for five operations: `list_doctors`,
  `get_doctor_schedule`, `book_appointment`, `cancel_appointment`,
  `get_patient_appointments`.
- JWT-based authentication and Role-Based Access Control (RBAC) for
  the admin dashboard (`app_admin`, `tenant_admin`, `tenant_operator`).
- Real-time KPI emission (turns, resolved chats, CSAT feedback) to the
  internal Metricas service and rendering of those KPIs inside the
  admin dashboard.

---

## 3. Architectural Structures

### 3.1. Component-and-Connector (C&C) Structure

#### 3.1.1. C&C View

![Un Agent — Component-and-Connector view](cc_diagram.png)

*Source: `C_C_Diagram` (draw.io). Companion diagrams in the same
folder: `Arquitictura-flow.drawio`,
`Desacoplo_-_Diagrama_C_C.drawio`.*

The dashed rectangle delimits the platform boundary. Four external
systems sit outside it: **Telegram Bot API**, **MongoDB Atlas**,
**Supabase** (managed Postgres), and **OpenRouter** (LLM gateway).
Inside the boundary, the **Agent Orchestrator** is the only component
exposed to clients; every other backend service is reachable only
through it or through the Agent Runtime.

#### 3.1.2. Architectural Styles

The prototype combines four complementary architectural styles. Each
one solves a different concern of the system.

**1. Microservices (primary style).**
The system is decomposed into independently deployable services
(`chat-orch`, `Tenant`, `conversation-chat`, `agent-runtime`,
`Hospital-MP`, `Metricas`, `FrontEnd`), each with its own repository,
technology stack, and release cycle. Services communicate
exclusively over the network. This style directly satisfies the
project's distributed-architecture and multi-language requirements.

**2. Backend-For-Frontend (BFF) / Gateway.**
The Agent Orchestrator (`chat-orch`) is the single HTTP front-door
for every client (web chat, admin dashboard, Telegram). The
frontend never talks directly to `Tenant`, `Metricas`, or
`conversation-chat`; it only knows about `chat-orch`. This keeps
CORS scope, auth, and rate-limiting concerns in exactly one place
and lets internal services evolve without coordinating releases
with the UI.

**3. Layered runtime — Agent Orchestrator → Agent Runtime → Conversation.**
The chat path is split into three logical layers:

- **Agent Orchestrator** (`chat-orch`, Rust) owns transport,
  authentication, and fan-out to the support services (`Tenant`,
  `Metricas`).
- **Agent Runtime** (`agent-runtime`, TypeScript/Express) owns the
  per-turn LLM tool-calling loop, the agent profile registry (ACR
  stub), the tenant stub, and the session/turn adapter to
  `conversation-chat`. It is the only component that knows the
  agent's prompt and the Hospital tool schemas.
- **Conversation/Chat** (`conversation-chat`, Go) owns durable
  session state (MongoDB Atlas), the turn history, and the actual
  streaming HTTP call to OpenRouter.

This keeps each concern in one place and lets, e.g., the LLM
provider be swapped without touching the orchestrator or the
session store.

**4. End-to-end Server-Sent Events (SSE) streaming.**
A single SSE chain carries assistant tokens from the model all
the way to the browser, with every hop preserving the streaming
semantics:

```
OpenRouter ──HTTP SSE──► conversation-chat ──HTTP SSE──► agent-runtime
                                                               │
                          HTTP SSE◄──────────────────────────  ▼
                              ▲                           chat-orch
                              │                                │
                              └────────── HTTP SSE ◄───────────┘
                                            │
                                            ▼
                                         browser
```

Each hop is a simple HTTP GET whose response body is a
`text/event-stream` with a 15-second keep-alive ping. This avoids
buffering the full LLM reply before showing it to the user.

In addition, telemetry emissions from `chat-orch` to `Metricas`
are fire-and-forget (spawned onto Tokio, failures logged only) so
they never block the request path.

#### 3.1.3. Architectural Elements

The system exposes one frontend component, six backend services, two
hosted external datastores, two local stateful containers, and two
external SaaS services (LLM and channel).

**Presentation component**

| Component | Stack | Responsibility |
|---|---|---|
| `FrontEnd` (single repo) | React 19 + Vite + TypeScript + Tailwind + shadcn/ui + Zustand + TanStack Query + recharts | Ships **two sub-apps** in one codebase: the patient-facing chat console and the tenant-admin dashboard. Both only call `chat-orch` (and `Tenant` for login). Renders its own KPI charts (10-second refetch via TanStack Query) from the JSON payload returned by `Metricas`. |

**Logic components**

| Component | Stack | Responsibility |
|---|---|---|
| `chat-orch` — Agent Orchestrator | Rust 2021, Axum 0.7, Tokio | BFF / gateway. Terminates REST + SSE from the frontend and Telegram long-poll. Delegates per-turn work to the Agent Runtime, streams the SSE response back to the browser. Proxies admin reads/writes to `Tenant` and `Metricas`. Emits fire-and-forget telemetry. |
| `agent-runtime` — Agent Runtime | TypeScript, Express 5, Node.js 20 | LLM tool-calling loop + ACR stub + tenant stub + session proxy. Assembles the system prompt + history + the five Hospital-MP tool schemas, parses model `tool_calls`, dispatches them, and feeds the results back into the loop (≤ 5 rounds). Adapts `chat-orch`'s thin `OpenSessionRequest` / `TurnRequest` into the full payload expected by `conversation-chat`. |
| `conversation-chat` — Conversation Service | Go + Gin + MongoDB driver + go-openai | Durable session and per-turn history. Streams the OpenRouter chat-completions response back up to the Agent Runtime. Persists session records and tool traces to MongoDB Atlas. |
| `Tenant` — Tenant & RBAC Service | Go + Gin + bcrypt + JWT (HS256) | JWT login (`/auth/login`), tenant CRUD, user roster, RBAC (`app_admin`, `tenant_admin`, `tenant_operator`). Exposes `/health` for compose healthchecks. Source of truth for tenant identity. |
| `Metricas` — Internal KPI Engine | Go + Gin + prometheus client | In-memory counters and daily buckets per tenant. Exposes `/stats/kpis` (cards), `/stats/timeseries` (chart), `/conversation/chat` (event ingest), `/feedback/csat`, and `/metrics` (Prometheus exposition). The dashboard reads it through `chat-orch`. |
| `Hospital-MP` — Hospital Mock API | Python 3 + Flask | Simulated hospital data source. In-memory doctors and appointments. Five scheduling operations invoked by the Agent Runtime tool loop. |

**Data components**

| Component | Type | Hosting | Owner | Role |
|---|---|---|---|---|
| Supabase PostgreSQL | Relational | External SaaS | `Tenant` | Tenants, users, `user_tenants` (RBAC join). Connected via the **Session Pooler** URI (IPv4-compatible). |
| MongoDB Atlas | NoSQL (document) | External SaaS | `conversation-chat` | Durable session records, full per-turn history, tool call traces. |
| Qdrant | NoSQL (vector) | Local container, `qdrant-data` volume | Reserved for embeddings | Vector store provisioned in compose for the platform; ready for retrieval-augmented context in P2. |
| Redis | In-memory cache | Local container | `conversation-chat` | Active session cache used by `conversation-chat`. |
| In-process state | Volatile | In-process | `Metricas`, `Hospital-MP`, `chat-orch`, `agent-runtime` | KPI counters, hospital catalogue, per-session message buffer, and in-memory agent profile registry respectively. Reset on container restart. |

**External services (outside the platform boundary)**

| Component | Protocol | Role |
|---|---|---|
| OpenRouter | HTTP + SSE | OpenAI-compatible LLM gateway with token streaming. Default model `nvidia/nemotron-3-super-120b-a12b:free`. Consumed by `conversation-chat`. |
| Telegram Bot API | HTTPS long-poll | Inbound messaging channel. `chat-orch` calls `getUpdates` with a 30-second server timeout. |

Both a **relational** store (Supabase PostgreSQL) and **two NoSQL**
stores (MongoDB Atlas — document, Qdrant — vector) are present,
satisfying the two-data-type requirement with margin to spare.

#### 3.1.4. Connectors and Relations

Three HTTP-based connector families are used on the critical chat
path. This satisfies the "at least two different types of HTTP-based
connectors" requirement. Two database wire protocols complete the
picture.

| # | Connector | Protocol | Where it is used |
|---|---|---|---|
| 1 | **REST (synchronous request/response)** | JSON over HTTP/1.1 | `FrontEnd → chat-orch` for non-streaming calls. `FrontEnd → Tenant` for login. `chat-orch → agent-runtime` (session + turn). `agent-runtime → conversation-chat`. `agent-runtime → Hospital-MP` (tool dispatch). `chat-orch → Metricas` (telemetry). |
| 2 | **Server-Sent Events (SSE)** | HTTP/1.1, `text/event-stream`, 15 s keep-alive | End-to-end streaming chain in the chat-path: `OpenRouter → conversation-chat → agent-runtime → chat-orch → FrontEnd`. Every hop preserves the stream so assistant tokens appear in the UI as they are generated. |
| 3 | **HTTP long-polling** | HTTPS `GET /bot{token}/getUpdates?timeout=30` | `Telegram Bot API ↔ chat-orch`. Enables bot input without exposing a public webhook during development. |
| 4 | **PostgreSQL wire protocol** | TCP (Supabase Session Pooler, IPv4) | `Tenant ↔ Supabase`. Labelled "DB CONNECTOR" in the diagram. |
| 5 | **MongoDB wire protocol** | TCP (Atlas SRV) | `conversation-chat ↔ MongoDB Atlas`. Labelled "DB CONNECTOR" in the diagram. |

**Key relations.** The numbered arrows correspond to one complete chat turn.

1. The browser posts `{tenant_id, session_id?, message}` to
   `POST /v1/chat` on `chat-orch`, and opens an SSE subscription on
   `GET /v1/chat/stream?session_id=...`.
2. `chat-orch` emits a `resolved:false` telemetry event to `Metricas`
   (fire-and-forget) and hands the turn to the Agent Runtime.
3. If no session exists, `agent-runtime` opens one against
   `conversation-chat`, which loads the session history from MongoDB
   Atlas and calls OpenRouter `POST /chat/completions?stream=true`.
4. OpenRouter streams the LLM reply back over SSE through
   `conversation-chat → agent-runtime`. If the model emits
   `tool_calls`, the runtime dispatches them to `Hospital-MP` (REST)
   and feeds the results back into the loop, capped at 5 rounds.
5. Once the LLM returns plain content, `conversation-chat` appends
   the turn to MongoDB Atlas, and the SSE chain delivers each token
   straight through `chat-orch` to the browser.
6. If a `book_appointment` tool call succeeded during the turn,
   `chat-orch` emits a `resolved:true` telemetry event to `Metricas`.
7. The admin dashboard pulls KPIs from `Metricas`
   (`GET /stats/kpis` and `GET /stats/timeseries`); login exchanges
   credentials for a JWT at `Tenant` `POST /auth/login`. The
   frontend stores the token in a Zustand store and attaches it to
   subsequent requests.

**Protection of the architecture.** Only the frontend, the Agent
Orchestrator, and the Tenant service are reachable from outside the
compose network. Every non-public endpoint requires an RBAC-validated
JWT issued by `Tenant`. Secrets (OpenRouter key, JWT secret, Supabase
password, Atlas connection string, Telegram bot token) live in a
root-level `.env`, gitignored and never committed.

#### 3.1.5. Requirement Traceability

| Non-functional requirement | How it is met |
|---|---|
| Distributed architecture | Six independently deployable backend services plus a frontend, all communicating over the network. |
| ≥ 1 presentation component | `FrontEnd` (single React/Vite repo hosting both the chat console and the admin dashboard). |
| ≥ 2 logic components | `chat-orch`, `agent-runtime`, `conversation-chat`, `Tenant`, `Metricas`, `Hospital-MP` (6 total). |
| ≥ 2 data components (relational + NoSQL) | Supabase PostgreSQL (relational) + MongoDB Atlas (document NoSQL) + Qdrant (vector NoSQL). |
| ≥ 2 different HTTP-based connectors | REST, SSE, HTTP long-polling (3 total). |
| ≥ 3 general-purpose languages | Rust (`chat-orch`), Go (`Tenant`, `Metricas`, `conversation-chat`), Python (`Hospital-MP`), TypeScript (`FrontEnd`, `agent-runtime`) — **4 languages**. |
| Container-oriented deployment | Every service ships a `Dockerfile`; the full stack is orchestrated via Docker Compose from the `dev-runner` umbrella repo. |

---

## 4. Prototype

### 4.1. Source Repositories

The platform is shipped as a `dev-runner` umbrella repository that
pins each service repo as a **git submodule**. One clone with
`--recurse-submodules` reproduces the exact working stack.

All repositories live under the `UNagent-1D` GitHub organization:
<https://github.com/UNagent-1D>

| Path in umbrella | Upstream repo | Language | Role |
|---|---|---|---|
| `chat-orch/` | `UNagent-1D/chat-orch` | Rust | Agent Orchestrator + SSE hub + Telegram long-poll |
| `agent-runtime/` | `UNagent-1D/agent-runtime` | TypeScript | Agent Runtime (ACR stub, tenant stub, session proxy) |
| `Tenant/` | `UNagent-1D/Tenant` | Go | Auth + tenant admin API |
| `conversation-chat/` | `UNagent-1D/conversation-chat` | Go | Session + history service (MongoDB Atlas + OpenRouter) |
| `Hospital-MP/` | `UNagent-1D/Hospital-MP` | Python | Mock hospital scheduling API |
| `Metricas/` | `UNagent-1D/Metricas` | Go | KPI service backing the Analytics dashboard |
| `FrontEnd/` | `UNagent-1D/FrontEnd` | TypeScript | React 19 admin dashboard + chat console |

```bash
# 1. Clone with submodules in one shot
git clone --recurse-submodules \
  git@github.com:UNagent-1D/dev-runner.git
cd dev-runner
```

To bump every submodule to its tracked upstream `main` later:

```bash
git submodule update --remote --merge
git add . && git commit -m "chore: bump submodules" && git push
```

### 4.2. Prerequisites

- **Docker** ≥ 24 and **Docker Compose v2**
- An **OpenRouter API key** (<https://openrouter.ai/keys>)
- A **MongoDB Atlas** cluster + SRV connection string
- A **Supabase** project — use the **Session Pooler** URI (IPv4); the
  direct URL is IPv6-only on the free tier
- *(Optional)* A **Telegram bot token** from `@BotFather`

### 4.3. Environment Configuration

```bash
cp .env.example .env
# Fill in:
#   OPENROUTER_API_KEY     = sk-or-v1-...
#   JWT_SECRET             = (long random string)
#   DATABASE_URL           = postgresql://postgres:PWD@<pooler>.supabase.co
#                            :5432/postgres?sslmode=require
#   MONGO_URI              = mongodb+srv://USER:PWD@CLUSTER.mongodb.net/
#                            ?retryWrites=true&w=majority
#   MONGO_DB               = conversatory
#   TELEGRAM_BOT_TOKEN         (optional)
#   TELEGRAM_DEFAULT_TENANT_ID = demo-tenant
```

### 4.4. One-Time Database Seed (Supabase)

```bash
docker run --rm -i postgres:16-alpine \
  psql "$(grep ^DATABASE_URL .env | cut -d= -f2-)" <<'SQL'
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS pgcrypto;
DO $$ BEGIN
  CREATE TYPE system_role AS ENUM ('app_admin','tenant_admin','tenant_operator');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS tenants (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  domain VARCHAR(255) UNIQUE,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS users (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  email VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  first_name VARCHAR(100) NOT NULL,
  last_name VARCHAR(100) NOT NULL,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS user_tenants (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  role system_role NOT NULL,
  assigned_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT unique_user_tenant UNIQUE (user_id, tenant_id),
  CONSTRAINT check_role_tenant_logic CHECK (
    (role = 'app_admin' AND tenant_id IS NULL)
    OR (role IN ('tenant_admin','tenant_operator') AND tenant_id IS NOT NULL)
  )
);

INSERT INTO users (email, password_hash, first_name, last_name)
VALUES ('admin@demo.local', crypt('demo1234', gen_salt('bf', 10)),
        'Demo', 'Admin')
ON CONFLICT (email) DO NOTHING;

INSERT INTO user_tenants (user_id, tenant_id, role)
SELECT id, NULL, 'app_admin' FROM users WHERE email='admin@demo.local'
ON CONFLICT (user_id, tenant_id) DO NOTHING;
SQL
```

### 4.5. Run the Full Stack

From the `dev-runner` root:

```bash
docker compose up --build -d
```

Sign in at <http://localhost:3000> with `admin@demo.local` / `demo1234`.

Useful day-to-day commands:

```bash
docker compose logs -f chat-orch          # tail one service
docker compose up -d --build chat-orch    # rebuild only one service
docker compose down                       # stop and clean up
```

### 4.6. Service URLs (host-exposed)

| Service | URL | Purpose |
|---|---|---|
| `FrontEnd` | <http://localhost:3000> | User entry point — chat + dashboard |
| `chat-orch` | <http://localhost:8000> | Agent Orchestrator — REST + SSE |
| `agent-runtime` | <http://localhost:3100> | Agent Runtime — tools + proxy |
| `Tenant` | <http://localhost:8080> | Auth + tenant admin |
| `conversation-chat` | <http://localhost:8082> | Sessions + LLM stream |
| `Metricas` | <http://localhost:8091> | KPI engine |
| `Hospital-MP` | <http://localhost:8092> | Hospital simulated API |
| Qdrant | <http://localhost:6333> | Vector store |

Inside the compose network, services address each other by container
name (`chat-orch:3000`, `tenant:8080`, `agent-runtime:3100`, etc.).
The host ports above are published for debugging only.

### 4.7. Smoke Tests

```bash
# 1. chat-orch liveness
curl -s http://localhost:8000/health
# -> {"status":"ok"}

# 2. Tenant liveness (DB ping)
curl -s http://localhost:8080/health
# -> {"service":"tenant","status":"ok"}

# 3. Open a chat turn (a session_id is minted on the first call)
curl -s -X POST http://localhost:8000/v1/chat \
  -H 'content-type: application/json' \
  -d '{"tenant_id":"demo-tenant",
       "message":"¿Qué cardiólogos tienen disponibles?"}'

# 4. Subscribe to the SSE stream for that session_id
curl -Ns "http://localhost:8000/v1/chat/stream?session_id=<sid>"

# 5. Submit CSAT feedback (fire-and-forget to Metricas)
curl -s -X POST http://localhost:8000/v1/feedback \
  -H 'content-type: application/json' \
  -d '{"tenant_id":"demo-tenant","score":5}'

# 6. Admin login
curl -s -X POST http://localhost:8080/auth/login \
  -H 'content-type: application/json' \
  -d '{"email":"admin@demo.local","password":"demo1234"}'

# 7. KPIs
curl -s http://localhost:8091/stats/kpis
```

---

## 5. Delivery Notes

- Artefact format: `.md` exported to `.pdf`, named `p1_1D.pdf`.
- Delivery channel: GitHub MiCampus UNAL.
- Deadline: Monday, April 20, 2026.
- Presentation: Tuesday, April 21, 2026.
