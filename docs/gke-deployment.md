# UNAgent — GKE Deployment Reference (for the deployment diagram)

Live since 2026-06-09 (Railway decommissioned). Two identical environments on
one cluster; everything below exists once per namespace unless marked global.

---

## 1. Devices / external nodes

| Node | Role |
|---|---|
| End-user browser | SPA + same-origin API calls to `unagent.site` / `dev.unagent.site` |
| End-user phone (Telegram app) | Chats with `UNAgent_bot` (prod) / `UnAgent-dev` (dev) |
| Operator browser | Operator Panel (claims escalations, replies as human) |
| **Cloudflare edge** (global) | Worker `unagent-gateway[-dev]`: serves the static SPA (FrontEnd `dist/` bundled as Worker assets) and reverse-proxies all API paths to the env's GCLB origin over HTTPS |
| **Telegram Bot API** (SaaS) | chat-orch-telegram long-polls `getUpdates`, sends `sendMessage` |
| **OpenRouter** (SaaS) | LLM gateway — model `deepseek/deepseek-v4-flash` (all consumers) |
| **SendGrid** (SaaS) | Outbound email (OTP codes, booking confirmations); verified sender `nizulu1998@gmail.com` |

## 2. DNS (Cloudflare zone `unagent.site`)

| Record | Type | Target | Proxy |
|---|---|---|---|
| `unagent.site` | Worker route (custom domain) | `unagent-gateway-prod` | proxied |
| `dev.unagent.site` | Worker route (custom domain) | `unagent-gateway-dev` | proxied |
| `api.unagent.site` | A | `34.54.189.213` (GCLB prod) | DNS-only |
| `api-dev.unagent.site` | A | `8.233.227.226` (GCLB dev) | DNS-only |

## 3. Google Cloud (project `unagent-498915`)

| Resource | Spec |
|---|---|
| GKE cluster `unagent` | Standard, zonal `us-central1-a`, 3 × `e2-standard-2` (2 vCPU / 8 GB each), **Dataplane V2 (Cilium)** → NetworkPolicies enforced, release channel regular |
| Artifact Registry `unagent` | Docker repo, `us-central1`; images `us-central1-docker.pkg.dev/unagent-498915/unagent/<svc>:<git-sha>` |
| Global static IPs | `unagent-prod-ip` = 34.54.189.213, `unagent-dev-ip` = 8.233.227.226 |
| 2 × External HTTPS LB (GCLB) | one per env, created by the Ingress; Google **ManagedCertificate** per hostname; `BackendConfig` `timeoutSec: 86400` (SSE-safe), health check `GET / :80` |
| Namespaces | `unagent-prod` (apex), `unagent-dev` |

## 4. Application workloads (per namespace)

| Workload | Kind | Replicas | Port | Lang/Runtime | Notes |
|---|---|---|---|---|---|
| `frontend` | Deployment | 1 | 80 | nginx | **In-cluster gateway**: serves SPA + routes `/v1`, `/auth`, `/api/*`, `/stats` to backends (mirrors the Worker's table). ClusterIP + container-native NEG behind the Ingress |
| `chat-orch` | Deployment | **2 (active/standby)** | 3000 | Rust (Axum) | Web orchestrator: LLM turn loop, SSE hub, in-memory SessionStore. Service has `sessionAffinity: ClientIP` (a session's POST + SSE stream must share a pod) |
| `chat-orch-telegram` | Deployment | **1** | 3000 | Rust (same image) | Sole holder of `TELEGRAM_BOT_TOKEN` — one `getUpdates` poller per env (two would 409). Egress-only; no Service |
| `conversation-chat` | Deployment + **HPA 2–6** (CPU 70%) | 2+ | 8082 | Go (Gin) | Sessions, turn history, escalation state machine, RabbitMQ worker, LLM calls. State externalized → freely scalable |
| `agent-runtime` | Deployment | **1** | 3100 | Node (Express) | ACR stub + session proxy + Telegram jobs broker (**in-memory job registry → must stay 1 replica**) |
| `tenant` | Deployment | 1 | 8080 | Go (Gin) | Auth (JWT issuer) + tenant admin API |
| `user-auth` | Deployment | 1 | 8080 | Go | OTP pre-registration (Telegram); 15-min code expiry |
| `hospital-mock` | Deployment | 1 | 8080 | Python (Flask) | Doctors/appointments API (the LLM's tools) |
| `compliance` | Deployment | 1 | 8091 | Python (FastAPI) | KPI counters (in-memory) + audit log → email-mongo |
| `email-send` | Deployment | 1 | 8080 | Java (Spring Boot) | SendGrid dispatch + audit (`email_audit.email_events`); sandbox OFF |
| `grafana` | Deployment | 1 | 3000 | — | Observability (emptyDir) |

## 5. Data stores (per namespace, all PVC `standard` 1 Gi)

| Store | Kind | Replicas | Port | Used by |
|---|---|---|---|---|
| `email-mongo` | StatefulSet + headless Svc | **3 — replica set `rs0`** (pattern #1; `make failover` demos re-election) | 27017 | email-send (audit), compliance (audit_logs) |
| `conversation-mongo` | StatefulSet | 1 | 27017 | conversation-chat (session records) |
| `redis` | StatefulSet | **2 — primary/replica** (`redis-1 --replicaof redis-0`; client Service pinned to `redis-0`) | 6379 | conversation-chat (live session state, op queue, outbound) |
| `rabbitmq` | StatefulSet | 1 | 5672 | `chat_requests` / `chat_results` queues (Telegram async path) |
| `tenant-postgres` | StatefulSet | 1 | 5432 | tenant (`tenants/users/user_tenants`) + user-auth (`user_auth` DB) |
| `hospital-postgres` | StatefulSet | 1 | 5432 | hospital-mock (schema+seed at first boot) |

**One-shot Jobs** (idempotent, re-run per deploy): `email-mongo-rs-init`
(rs.initiate), `tenant-migrate` (golang-migrate), `tenant-seed` (demo tenant
`ce5ac1c5-9b16-486a-b091-5468d232a4b8` + `admin@demo.com`).

## 6. Communication paths (diagram arrows)

External (all TLS on :443):
1. Browser → Cloudflare Worker (HTTPS :443) — SPA assets + every API path
2. Worker → `https://api[-dev].unagent.site` :443 (GCLB terminates TLS) → `frontend` nginx :80
3. Telegram app → Telegram Bot API :443 ← long-poll (`getUpdates`) — `chat-orch-telegram`
4. chat-orch / chat-orch-telegram / conversation-chat → OpenRouter :443 (HTTPS)
5. email-send → SendGrid :443 (HTTPS); user-auth OTP mail rides path 16 → SendGrid

In-cluster (all HTTP unless noted; **AES-256-GCM secure channel ON** for every backend↔backend hop, HTTP + RabbitMQ):
6. frontend → chat-orch :3000 (`/v1/*`, SSE stream; ClientIP-pinned)
7. frontend → tenant :8080 (`/auth/*`, `/api/admin`, `/api/v1/{tenants,users,auth,tool-registry}`)
8. frontend → user-auth :8080 (`/auth/{request,verify,resend}-code`, `/auth/users`)
9. frontend → conversation-chat :8082 (`/api/v1/{sessions,escalations}`)
10. frontend → compliance :8091 (`/stats/*`)
11. chat-orch → agent-runtime :3100 (session open/turns proxy + Telegram jobs)
12. chat-orch → tenant :8080, → hospital-mock :8080, → compliance :8091, → user-auth :8080 (OTP gate)
13. chat-orch-telegram → conversation-chat :8082 (`/api/v1/outbound/drain` poll, 2 s)
14. agent-runtime → conversation-chat :8082; agent-runtime ↔ rabbitmq :5672 (publish `chat_requests`, consume `chat_results`)
15. conversation-chat ↔ rabbitmq :5672 (worker, competing consumers) · → redis :6379 · → conversation-mongo :27017 · → hospital-mock :8080 (LLM tools) · → email-send :8080 (appointment-confirmation emails) · → tenant/agent-runtime (ACR + auth stubs)
16. user-auth → tenant-postgres :5432 · → email-send :8080 (OTP mail) · → tenant :8080 (internal)
17. tenant → tenant-postgres :5432; hospital-mock → hospital-postgres :5432
18. compliance + email-send → email-mongo rs0 :27017 (replica-set URI)

## 7. Network segmentation (12 NetworkPolicies, enforced by Dataplane V2)

`default-deny-ingress` + per-zone allows; a pod's zone labels = who it can talk to.

| Zone | Members |
|---|---|
| `net-public` | frontend, chat-orch, grafana |
| `net-orch` | frontend, chat-orch(+telegram), conversation-chat, agent-runtime, tenant, hospital-mock, user-auth, rabbitmq |
| `net-tenant` | frontend, tenant, email-send, user-auth |
| `net-compliance` | frontend, chat-orch(+telegram), compliance, grafana |
| `net-email` | email-send, user-auth, email-mongo, **conversation-chat** (confirmation emails) |
| `net-tenant-db` | tenant, user-auth, tenant-postgres, migrate/seed jobs |
| `net-chat-db` | conversation-chat, redis, conversation-mongo |
| `net-hospital-db` | hospital-mock, hospital-postgres |
| Public allows | frontend :80, conversation-chat :8082 (any source — GCLB health checks) |

Egress unrestricted (DNS + OpenRouter/SendGrid/Telegram). Verify: `make -C k8s netcheck NS=unagent-<env>`.

## 8. Config & secrets flow

```
.env.prod / .env.dev (gitignored, source of truth)
        │ scripts/gke-secrets.sh <env>   (DSNs rebuilt against k8s DNS)
        ▼
Secret platform-secrets (per ns): OPENROUTER_API_KEY, JWT_SECRET,
  INTERNAL_API_KEY, BACKEND_CHANNEL_KEY, SENDGRID_API_KEY,
  TELEGRAM_BOT_TOKEN, POSTGRES passwords, DATABASE_URLs, SEED_PASSWORD
ConfigMap platform-config (per ns): OPENAI_BASE_URL,
  OPENAI_DEFAULT_MODEL=deepseek/deepseek-v4-flash,
  BACKEND_CHANNEL_ENABLED=true, EMAIL_MONGO_RS_URI, LOG_FORMAT, GIN_MODE
```

## 9. Deploy pipeline (manual — no CI/CD by design)

```
git commit  →  make -C k8s gke-build TAG=$(git rev-parse --short HEAD)
            →  make -C k8s gke-deploy ENV=prod|dev TAG=<same>
   (renders k8s/overlays/gke-<env> over the shared base k8s/platform/,
    asserts GKE-safety, sed-pins the tag, applies, waits for jobs)
FrontEnd UI →  cd FrontEnd && npm run build
            →  cd cloudflare-worker && npx wrangler deploy --env dev|prod
```

## 10. Suggested diagram grouping (UML deployment)

- **«device» User Browser** ── HTTPS ──> **«node» Cloudflare Edge** [Worker + SPA assets]
- **«device» Phone (Telegram)** ── HTTPS ──> **«node» Telegram API** <── long-poll ── chat-orch-telegram
- Cloudflare ── HTTPS ──> **«node» GCLB (per env)** [static IP + managed cert] ──> frontend nginx
- **«execution env» GKE cluster `unagent`** (3× e2-standard-2)
  - **«node» namespace unagent-prod / unagent-dev** each containing:
    - app tier (frontend, chat-orch ×2, chat-orch-telegram, conversation-chat ×2–6 HPA, agent-runtime, tenant, user-auth, hospital-mock, compliance, email-send, grafana)
    - data tier (email-mongo ×3 rs0, conversation-mongo, redis ×2, rabbitmq, tenant-postgres, hospital-postgres — each with «artifact» PVC)
- **«node» Artifact Registry** ── image pull ──> every workload
- SaaS nodes: OpenRouter, SendGrid (dashed dependency arrows from the consumers)
