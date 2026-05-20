# Attack surface review

Date: 2026-05-20. Snapshot of public-facing endpoints and concrete
weaknesses, ordered by severity. File:line references are into
`dev-runner/`.

## Critical

- Secrets committed in `.env`: OpenRouter API key (`.env:9`), MongoDB
  Atlas URI with password (`.env:23`), Telegram bot token (`.env:30`).
  Anyone with repo or history access has live credentials. Rotate all
  three and move `.env` out of version control.
- `POST /v1/chat` on chat-orch has no authentication
  (`chat-orch/src/routes.rs:65-145`). It only checks that `tenant_id`
  is present in the body. Rate limiting is per tenant, so one caller
  can exhaust a tenant's quota. `/v1/chat/stream` is also open and
  takes `session_id` from the URL, so a guessed id leaks a stream.

## High

- Hospital-MP `GET /patients/{ref}/appointments` has no auth
  (`Hospital-MP/app.py:298-314`). Patient references are guessable, so
  appointments for any patient can be enumerated.
- Compliance `GET /stats/kpis` and `/stats/timeseries` have no auth and
  return data across all tenants when `tenant_id` is omitted
  (`Compliance/main.py:322-383`).
- Tenant CORS reflects the `Origin` header and sets
  `Access-Control-Allow-Credentials: true` (`Tenant/router.go:187-203`).
  Any origin can make credentialed requests. Whitelist known origins.
- `AUTH_STUB: "true"` in `docker-compose.yml:170` makes conversation-chat
  bypass JWT and treat every caller as `app_admin`. Fine for local dev,
  must be `false` anywhere reachable.

## Medium

- JWT secret falls back to a hardcoded string when `JWT_SECRET` is
  unset (`Tenant/handlers/auth_handler.go:19`). Fail to start instead.
- agent-runtime tenant/profile/data-source endpoints have no auth. It
  is an internal service today, but nothing enforces that.
- chat-orch does not bound the `message` length
  (`chat-orch/src/routes.rs:69-74`). Add a max length.
- Compliance trusts the `X-Tenant-ID` header with no signing, so a
  caller can write audit rows under any tenant.

## Endpoints not rate-limited

Rate limiting today covers only Tenant `/auth/login`, chat-orch
`/v1/chat`, and `/v1/feedback`. Everything else (admin endpoints,
Hospital-MP, Compliance stats, conversation-chat, agent-runtime,
email-send) has none.

## Recommended order of fixes

1. Rotate the three leaked secrets, remove `.env` from the repo.
2. Authenticate `/v1/chat` (parked earlier as item #1; revisit).
3. Put the patient-appointments endpoint behind auth.
4. Scope Compliance stats to the caller's tenant.
5. Whitelist Tenant CORS origins.
6. Make `JWT_SECRET` and `AUTH_STUB` safe by default.
