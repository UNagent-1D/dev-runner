# dev-runner

Umbrella repo that boots the whole UNAgent platform locally with a single
`docker compose up --build`. Every service lives in its own repo; this
one pins them as git submodules so a fresh clone reproduces the exact
working stack.

## Documentation

- **[Prototype 1 — Software Architecture submission](docs/PROTOTYPE_1.md)** —
  team roster (1D), C&C view, architectural styles, connectors,
  requirement traceability, and quickstart. Exportable to
  `p1_1D.pdf` for MiCampus delivery.
- **[AGENTS.md](AGENTS.md)** — full agent/developer playbook for the
  platform: per-service cheat sheets, common tasks, and gotchas.
- **[scripts/bootstrap.md](scripts/bootstrap.md)** — first-time deploy
  to Railway (backends + self-hosted data stores) and Cloudflare (Worker
  + custom domain). One command, three human checklists.
- Brand assets (`Un Agent — Asesores en Salud`) live under
  [`LogosUNagent/`](LogosUNagent/); the horizontal lockup used in the
  P1 writeup is at [`docs/logo.png`](docs/logo.png).

## Deploying

Production target: Railway (Hobby) + Cloudflare. Each microservice is its
own Railway service; all stateful pieces (Redis, RabbitMQ, two Postgres
instances, two Mongo instances) are self-hosted on Railway with volumes —
no external SaaS for data. The FrontEnd ships to a Cloudflare Worker that
also reverse-proxies API paths to backends, so the browser sees one origin.

```bash
scripts/bootstrap.sh        # one-shot: Railway project + envs + Cloudflare Worker + custom domain
```

After that, push to `dev` or `main` triggers the matching environment via
GitHub Actions; `main` is gated on a green dev deploy of the same SHA. See
[scripts/bootstrap.md](scripts/bootstrap.md) for the three checklists you
fill in once.

## What's inside

| Path | Upstream | Default branch pinned | Role |
|---|---|---|---|
| `chat-orch/` | [UNagent-1D/chat-orch](https://github.com/UNagent-1D/chat-orch) | `main` | Rust/Axum orchestrator — runs the LLM turn loop + Telegram long-poll + SSE to the frontend |
| `Tenant/` | [UNagent-1D/Tenant](https://github.com/UNagent-1D/Tenant) | `main` | Go/Gin auth + tenant admin API |
| `conversation-chat/` | [UNagent-1D/conversation-chat](https://github.com/UNagent-1D/conversation-chat) | `main` | Go/Gin session + history service (wired via agent-runtime) |
| `agent-runtime/` | [UNagent-1D/agent-runtime](https://github.com/UNagent-1D/agent-runtime) | `main` | TypeScript/Express 5 proxy bridging chat-orch to conversation-chat |
| `Hospital-MP/` | [UNagent-1D/Hospital-MP](https://github.com/UNagent-1D/Hospital-MP) | `main` | Python/Flask mock hospital scheduling API |
| `Compliance/` | (in-tree, not a submodule) | N/A | Python/FastAPI KPI counters + daily buckets + audit-log writer |
| `FrontEnd/` | [UNagent-1D/FrontEnd](https://github.com/UNagent-1D/FrontEnd) | `main` | React 19 + Vite admin dashboard |
| `UN_email_send_ms/` | [UNagent-1D/UN_email_send_ms](https://github.com/UNagent-1D/UN_email_send_ms) | `main` | Java/Spring Boot email dispatch + audit (SendGrid + local Mongo) |

All submodules track their upstream `main`. Bump to the newest code
with `git submodule update --remote --merge`, then commit the pointer
changes.

## Hosted dependencies

- **Supabase Postgres** — Tenant service DB (auth, tenants). Use the
  Session Pooler URI (IPv4-compatible); the direct URL is IPv6-only.
- **MongoDB Atlas** — used by conversation-chat.
- **OpenRouter** — LLM provider; we read the key via `OPENAI_API_KEY`.
- **Telegram Bot** — optional; skip the token in `.env` to disable the
  channel.

The containerized stateful services include **Redis**, **RabbitMQ**, **hospital-postgres**, and **email-mongo** (local/volume-backed).

## Quickstart

```bash
# 1. Clone with submodules
git clone --recurse-submodules git@github.com:UNagent-1D/dev-runner.git
cd dev-runner

# 2. Secrets
cp .env.example .env
# …then fill in: OPENROUTER_API_KEY, JWT_SECRET, DATABASE_URL (Session
# Pooler), MONGO_URI, MONGO_DB, TELEGRAM_BOT_TOKEN, TELEGRAM_DEFAULT_TENANT_ID

# 3. (One-time) seed Supabase schema + admin user
docker run --rm -i postgres:16-alpine psql "$(grep ^DATABASE_URL .env | cut -d= -f2-)" <<'SQL'
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS pgcrypto;
DO $$ BEGIN
  CREATE TYPE system_role AS ENUM ('app_admin','tenant_admin','tenant_operator');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE TABLE IF NOT EXISTS tenants (id UUID DEFAULT gen_random_uuid() PRIMARY KEY, name VARCHAR(255) NOT NULL, domain VARCHAR(255) UNIQUE, is_active BOOLEAN DEFAULT true, created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS users (id UUID DEFAULT gen_random_uuid() PRIMARY KEY, email VARCHAR(255) UNIQUE NOT NULL, password_hash VARCHAR(255) NOT NULL, first_name VARCHAR(100) NOT NULL, last_name VARCHAR(100) NOT NULL, is_active BOOLEAN DEFAULT true, created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS user_tenants (id UUID DEFAULT gen_random_uuid() PRIMARY KEY, user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE, tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE, role system_role NOT NULL, assigned_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP, CONSTRAINT unique_user_tenant UNIQUE (user_id, tenant_id), CONSTRAINT check_role_tenant_logic CHECK ((role = 'app_admin' AND tenant_id IS NULL) OR (role IN ('tenant_admin','tenant_operator') AND tenant_id IS NOT NULL)));
INSERT INTO users (email, password_hash, first_name, last_name) VALUES ('admin@demo.local', crypt('demo1234', gen_salt('bf', 10)), 'Demo', 'Admin') ON CONFLICT (email) DO NOTHING;
INSERT INTO user_tenants (user_id, tenant_id, role) SELECT id, NULL, 'app_admin' FROM users WHERE email='admin@demo.local' ON CONFLICT (user_id, tenant_id) DO NOTHING;
SQL

# 4. Build + run everything
docker compose up --build -d
```

Sign in at http://localhost:3000 with `admin@demo.local` / `demo1234`.

## Service URLs (host-exposed)

| Service | URL |
|---|---|
| Frontend | http://localhost:3000 |
| Tenant API | http://localhost:8080 |
| conversation-chat | http://localhost:8082 |
| agent-runtime | http://localhost:3100 |
| chat-orch | http://localhost:8000 |
| Compliance | http://localhost:8091 |
| Hospital Mock | http://localhost:8092 |
| Email service | http://localhost:8089 |

Internally, services talk over the compose network by service name
(`tenant:8080`, `compliance:8091`, etc.).

## End-to-end demo flow

1. **Web chat** — log in, go to *Agent Console*, say
   *"¿Qué cardiólogos tienen disponibles?"*. The orch calls OpenRouter
   with the hospital tool registry, invokes `list_doctors`, replies via
   SSE.
2. **Telegram** — message @your_bot (set `TELEGRAM_BOT_TOKEN` in `.env`
   first). Same LLM brain, separate session bucket.
3. **Metrics** — *Analytics* refreshes every 10 s. Booking an
   appointment (*"Agéndame una cita con Dr. Mendoza…"*) increments
   `resolution_rate_percent`. Rating a chat via the CSAT stars updates
   `average_csat`.

## Updating submodules

To pull the latest on each tracked branch:

```bash
git submodule update --remote --merge
git add .
git commit -m "chore: bump submodules"
git push
```

## Notes

- `docker-compose.yml` references sub-repo paths relative to this root
  (e.g. `build: context: ./Tenant`). Submodule checkouts satisfy those
  paths, so no extra symlinking needed.
- The umbrella repo tracks each submodule as a **specific commit**, not
  a floating ref. To get the newest code, run
  `git submodule update --remote`.
- `.env` is gitignored. `.env.example` is the source of truth for the
  var list.
