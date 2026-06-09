# Interoperability Tactics — UNAgent Platform

How the platform achieves interoperability across every boundary — **internal**
(interfaces and contracts between our own services) and **external** (the third-party
APIs we consume). The mapping uses the classic interoperability-tactic categories:
**Locate** (Discover Service) and **Manage Interfaces** (Orchestrate, Tailor Interface).

> Note: the architecture docs (`docs/p2_1D.md`, `docs/quality-scenarios.md`) frame these
> as *patterns* (BFF, layered runtime, pub/sub). The tactic labels below are the
> architectural-tactics reading of those same artifacts.

| Scope | Interface / hop | Protocol / contract | Tactic |
|---|---|---|---|
| Internal | FrontEnd → `chat-orch` / `Tenant` / `Compliance` | REST + SSE (`/v1/chat`, `/v1/chat/stream`, `/auth/*`, `/stats/*`), JSON bodies, `Authorization: Bearer` JWT | **Orchestrate** (BFF front-door) |
| Internal | `chat-orch` → `agent-runtime` | thin chat payload over HTTP (`AGENT_RUNTIME_URL`) | **Orchestrate** |
| Internal | `agent-runtime` → `conversation-chat` | adapter translates thin payload → `OpenSessionRequest` / `TurnRequest` (`routes/proxy.ts`) | **Tailor Interface** (core adapter) |
| Internal | `chat-orch` → `Compliance` | preserves the *legacy Metricas wire contract* (`/conversation/chat`, `/feedback/csat`, `X-Tenant-ID`) | **Tailor Interface** (back-compat) |
| Internal | `agent-runtime` ↔ ACR / tenant stubs | `getProfile()` resolves agent profile by id (`registry.ts`) | **Discover Service** (stub seam) |
| Internal | `chat-orch` ↔ `conversation-chat::worker` ↔ `agent-runtime::broker` | RabbitMQ durable queues `chat_requests` / `chat_results` (AMQP) | **Orchestrate** (async pub/sub) |
| Internal | any backend ↔ backend | AES-256-GCM **Secure Channel** envelope; middleware accepts plaintext-or-sealed during rollout (`BACKEND_CHANNEL_ENABLED`) | **Tailor Interface** (format negotiation) |
| Internal | service → service addressing | static binding via Docker service names / Railway internal hostnames injected as env (`CONVERSATION_CHAT_URL`, …) | **Discover Service** (static form) |
| External | **OpenRouter** (LLM) | OpenAI-compatible Chat Completions + SSE, function/tool-calling schema; absorbed in `chat-orch/src/llm.rs` and the `conversation-chat` LLM client | **Tailor Interface** (absorb the OpenAI wire format) |
| External | **Telegram Bot API** | `getUpdates` long-poll ingress + `sendMessage` egress (`chat-orch/src/telegram.rs`), normalized into the same `run_turn` path as web chat | **Tailor Interface** (ingress normalization) |
| External | **SendGrid** (email) | Web API v3, sandbox mode, retry-once-on-5xx; behind an `EmailProvider` interface (`SendGridEmailProvider.java`) so the provider is swappable | **Tailor Interface** (provider behind a port) |
| External | **Supabase Postgres** | SQL via `lib/pq`, Session Pooler / IPv4 (`Tenant/config/database.go`) | **Tailor Interface** (conform to the driver) |
| External | **MongoDB Atlas** | mongo-driver SRV URI (`conversation-chat`) — session + history store | **Tailor Interface** (conform to the driver) |
| External | **Cloudflare** | Worker runtime routing + DNS/TLS at the edge (`cloudflare-worker/src/index.ts`); both edge gateway and external TLS/DNS provider | **Tailor Interface** (edge routing) |

**Reading the table.** Internally we lean on **Orchestrate** (`chat-orch` + RabbitMQ)
plus our own adapters and back-compat contracts; externally every vendor API is wrapped
by a **Tailor-Interface** adapter that conforms to the vendor's contract while shielding
the rest of the platform from it. **Discover Service** appears only in its static-binding
form, with the ACR registry (`agent-runtime/registry.ts`) as the seam where real
per-tenant service discovery would plug in.

---

## Patterns and why we chose them

| Pattern | Why |
|---|---|
| **BFF / API Gateway** (`chat-orch`) | One front-door for every client, so CORS, auth, and rate-limiting live in one place and internal services can change without breaking the UI. |
| **Adapter** (`agent-runtime` proxy, `EmailProvider`, `llm.rs`) | Translate between mismatched contracts at the seam, so neither side has to know the other's shape. |
| **Anti-corruption layer** (vendor schemas absorbed at the edge) | Keep third-party contracts (OpenAI, Telegram, SendGrid) from leaking inward, so a vendor swap stays local. |
| **Pub/Sub messaging** (RabbitMQ) | Decouple the synchronous front-door from slow background work, so producers and consumers interoperate without being up at the same time. |
