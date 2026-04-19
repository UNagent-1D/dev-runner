# dev-runner

Umbrella repo that boots the whole UNAgent platform locally with a single
`docker compose up --build`. Every service lives in its own repo; this
one pins them as git submodules so a fresh clone reproduces the exact
working stack.

## What's inside

| Path | Upstream | Default branch pinned | Role |
|---|---|---|---|
| `chat-orch/` | [UNagent-1D/chat-orch](https://github.com/UNagent-1D/chat-orch) | `feat/orch-thin-forwarder` | Rust/Axum orchestrator — runs the LLM turn loop + Telegram long-poll + SSE to the frontend |
| `Tenant/` | [UNagent-1D/Tenant](https://github.com/UNagent-1D/Tenant) | `feat/dockerfile` | Go/Gin auth + tenant admin API |
| `conversation-chat/` | [UNagent-1D/conversation-chat](https://github.com/UNagent-1D/conversation-chat) | `main` | Go/Gin session service (used by operator flows; not on the hot path for the demo) |
| `Hospital-MP/` | [UNagent-1D/Hospital-MP](https://github.com/UNagent-1D/Hospital-MP) | `main` | Python/Flask mock hospital scheduling API |
| `Metricas/` | [UNagent-1D/Metricas](https://github.com/UNagent-1D/Metricas) | `feat/compose-integration` | Go/Gin KPI service (backs the Analytics dashboard) |
| `FrontEnd/` | [UNagent-1D/FrontEnd](https://github.com/UNagent-1D/FrontEnd) | `feat/analytics-metricas` | React 19 + Vite admin dashboard |

The feature branches above carry the full working code for the demo.
Once the PRs against each repo's `main` are merged, bump the submodules
(`git submodule update --remote`) and switch the `branch` entries in
`.gitmodules` back to `main`.

## Hosted dependencies

- **Supabase Postgres** — Tenant service DB (auth, tenants). Use the
  Session Pooler URI (IPv4-compatible); the direct URL is IPv6-only.
- **MongoDB Atlas** — used by conversation-chat.
- **OpenRouter** — LLM provider; we read the key via `OPENAI_API_KEY`.
- **Telegram Bot** — optional; skip the token in `.env` to disable the
  channel.

The only containerized stateful services are **Redis** and **Qdrant**
(both in-memory/volume-backed and local).

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
| chat-orch | http://localhost:8000 |
| Metricas | http://localhost:8091 |
| Hospital Mock | http://localhost:8092 |
| Qdrant | http://localhost:6333 |

Internally, services talk over the compose network by service name
(`tenant:8080`, `metricas:8080`, etc.).

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

## When the PRs land on main

Once each sub-repo's feature PR merges, switch `.gitmodules`:

```
sed -i 's|branch = feat/orch-thin-forwarder|branch = main|' .gitmodules
sed -i 's|branch = feat/analytics-metricas|branch = main|' .gitmodules
sed -i 's|branch = feat/compose-integration|branch = main|' .gitmodules
sed -i 's|branch = feat/dockerfile|branch = main|' .gitmodules
git submodule sync
git submodule update --remote --merge
git add .gitmodules <paths>
git commit -m "chore: track main on all submodules"
git push
```

Current open PRs:
- chat-orch: https://github.com/UNagent-1D/chat-orch/pull/6
- Tenant: https://github.com/UNagent-1D/Tenant/pull/2
- FrontEnd: https://github.com/UNagent-1D/FrontEnd/pull/1
- Metricas: https://github.com/UNagent-1D/Metricas/pull/1

## Notes

- `docker-compose.yml` references sub-repo paths relative to this root
  (e.g. `build: context: ./Tenant`). Submodule checkouts satisfy those
  paths, so no extra symlinking needed.
- The umbrella repo tracks each submodule as a **specific commit**, not
  a floating ref. To get the newest code, run
  `git submodule update --remote`.
- `.env` is gitignored. `.env.example` is the source of truth for the
  var list.
