# Project state — functionalities-dev work

Date: 2026-05-20. Team 1D, UNAgent platform.

This file tracks what works today, what is broken, and the decisions we
take while fixing it. The goal of this round of work is a coherent,
demoable system: Telegram chat that flows, and a multi-tenant story
where the UI and the backend agree with each other.

## What works today

- Tenant creation: UI screen, `POST /api/admin/tenants`, and the DB
  insert are all wired. Listing tenants works.
- User login: real DB-backed users, bcrypt password check, HS256 JWT
  with a 24h expiry. `POST /api/admin/users` creates users (app_admin
  only). Login is rate-limited per IP.
- Chat through the web console and Telegram reaches the LLM and gets
  a reply in the normal (non-escalated) case.
- Hospital mock API answers doctor, schedule, and appointment calls.
- Compliance audit log records events, including rate-limit rejections.

## What is broken

### Telegram (top priority)

Four separate bugs, all confirmed in code:

1. The bot replies with a literal "…" when the answer comes back
   empty. The worker in conversation-chat returns an empty string on
   any error, and chat-orch substitutes "…" instead of a real
   message. (`chat-orch/src/telegram.rs:151,165,211`,
   `conversation-chat/internal/worker/worker.go:159`)
2. Sessions never reset. chat-orch keeps a process-local
   `chat_sessions` map from Telegram chat id to session id and never
   clears it. A closed session keeps being reused.
   (`chat-orch/src/telegram.rs:43-64,127-134`)
3. The "Estamos conectándote con un operador" message repeats on
   every message once a session escalates. While in
   `StateEscalationPending` the service returns that same line for
   every turn. (`conversation-chat/internal/service/chat_service.go:99-110`)
4. After escalation the bot goes silent. No operator-claim path is
   wired to Telegram, so the session sits in escalation until its TTL
   expires, then closes; later messages hit a closed session.

### Multitenancy (UI and backend disagree)

| Feature | UI screen | Backend endpoint | Connected |
|---|---|---|---|
| Create tenant | yes | yes | yes |
| Configure data sources | yes | missing (404) | no |
| Configure agent profile | yes (mock data) | stubbed no-op | no |

- The data sources screen calls `/api/v1/tenants/:id/data-sources` on
  the Tenant service. That route does not exist. The only real data
  sources are hardcoded in `agent-runtime/src/routes/tenant-stub.ts`.
- The agent profile screen reads `mockAgentProfile` and its save calls
  are stubbed to return null. No backend stores profiles.
- `agent-runtime/src/registry.ts` `getProfile(id)` ignores the id and
  always returns the single hardcoded `hospitalProfile`. Every tenant
  gets the same bot.

### Other items raised by the team

- CI/CD lives inside dev-runner; dev-runner should be a dev-only
  runner, deployment should be separate.
- FrontEnd chat scroll bar does not scroll to the bottom.
- Data source endpoints (hospital mock URLs) are hardcoded, not
  configurable per tenant.
- Telegram has no `/start` reset and does not handle session end well.
- OTP / email user validation is not wired into a Telegram
  pre-registration flow.

## Verification (2026-05-20)

Verified end to end against the running stack, driving conversation-chat
directly (the Telegram ingress is blocked, see below):

- Escalation notice is sent once. Two further messages while
  `escalation_pending` returned empty text (no repeated "Estamos
  conectándote"). [bug 3]
- A message on a closed session returns "Esta conversación finalizó.
  Envía /start para comenzar una nueva." instead of an error. [bug 4]
- Operator handoff: accept -> operator-message -> outbound drain
  returned `["Un operador se ha unido...", "<operator reply>"]`;
  resolve(close) -> drain returned the closing notice. The escalation
  queue and history endpoints work.
- conversation-chat new endpoints, CORS preflight, and the local
  `conversation-mongo` all healthy. chat-orch and the FrontEnd build
  and serve; the operator route is reachable.

Not verified live — the `TELEGRAM_BOT_TOKEN` in `.env` returns 401
Unauthorized (the bot token is revoked/invalid). The Telegram-only
paths (`/start` reset, the dropped "…" on the Telegram egress, and
operator replies actually arriving in Telegram) need a valid token to
test. The code is in place and the drain contract chat-orch consumes
is verified.

## Decisions log

(Append decisions here as we make them, newest first.)

- 2026-05-20: conversation-chat now uses a local `conversation-mongo`
  container for sessions and history. The Atlas URI in `.env` was
  unreachable from the build environment (TLS handshake failure);
  `MONGO_URI` is commented out so the compose default takes over.
- 2026-05-20: FrontEnd Docker image moved from Node 20 to Node 22.
  The bundled pnpm version fails to install on Node 20.
- 2026-05-20: Operator handoff was built in full (queue, claim,
  operator replies, resolve). Operator replies reach Telegram users
  through a 2-second poll: chat-orch drains `outbound:<sid>` lists
  from conversation-chat. No websocket server.
- 2026-05-20: A dead or expired session is recovered by telling the
  user to send /start, rather than silently failing. Escalations that
  time out without an operator hand the chat back to the bot.
- 2026-05-20: Branch name for this round of work is `functionalities-dev`
  in every microservice that needs changes (`chat-orch`,
  `conversation-chat`, `FrontEnd`).
