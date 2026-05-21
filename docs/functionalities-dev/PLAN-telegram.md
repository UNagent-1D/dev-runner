# Feature plan — Seamless Telegram conversation

Date: 2026-05-20. Branch: `functionalities-dev` in `chat-orch` and
`conversation-chat` (the only two services this feature touches).

## Goal

A Telegram user can hold a normal back-and-forth with the bot. A new
conversation starts clean. When something fails, the user sees a real
message, never a bare "…". Escalation tells the user once that an
operator is coming, and does not spam. After a conversation ends, the
next message starts a fresh one instead of going silent.

## The four bugs and the fix for each

### 1. The "…" placeholder

Cause: `conversation-chat/internal/worker/worker.go:159` sets
`resultText = ""` on any error. chat-orch then sees an empty reply and
sends "…" (`chat-orch/src/telegram.rs:151,165,211`).

Fix:
- worker.go: on error, set `resultText` to a plain Spanish fallback,
  e.g. "Lo siento, tuve un problema procesando tu mensaje. Intenta de
  nuevo en un momento."
- telegram.rs: keep one guard. If the reply is still empty, send the
  same fallback string instead of "…". Define it once as a const.

### 2. Sessions never reset

Cause: chat-orch's `chat_sessions` map (chat id -> session id) is never
cleared (`telegram.rs:43-64,127-134`).

Fix:
- Handle `/start` in `handle_update`: remove the chat id from
  `chat_sessions`, call `CloseSession` on the old session if one
  exists, reply with a short greeting. The next message creates a new
  session.
- Also clear the map entry whenever conversation-chat reports the
  session is closed (see bug 4).

### 3. "Estamos conectándote..." repeats every turn

Cause: while a session is in `StateEscalationPending`,
`chat_service.go:99-110` returns that same line for every turn.

Fix:
- Send the escalation notice once, on the transition into escalation
  (the "escalate" branch already returns a message — keep that).
- For later turns while still pending: append the user's turn to
  history (so the operator sees it) but return no message to send, or
  a one-time "Tu mensaje fue recibido" only if nothing was sent in the
  last N seconds. Telegram side: when the reply is intentionally
  empty, send nothing.

### 4. Bot goes silent after escalation / on a closed session

Cause: once the escalation TTL expires the session closes; later
messages hit a closed session and error out, and chat-orch keeps the
stale id.

Fix:
- conversation-chat: when a turn arrives for a closed session, return
  a clear, typed "session closed" signal (not a generic error).
- chat-orch: on that signal, drop the `chat_sessions` entry, create a
  fresh session, and process the message in it. The user simply
  continues and a new conversation begins.

## Out of scope for this feature (expansions, planned next)

- Operator-claim path wired to Telegram (so a human can actually take
  over instead of the TTL just expiring).
- Telegram pre-registration / OTP flow.
- Per-tenant routing of Telegram chats (today everything uses
  `TELEGRAM_DEFAULT_TENANT_ID`).

## Verification

With the stack up:
1. Send a normal message -> get a real reply, no "…".
2. Send `/start` mid-conversation -> greeting, and the following
   message is answered in a new session.
3. Force a worker error -> user sees the Spanish fallback, not "…".
4. Trigger escalation -> "Estamos conectándote..." appears once;
   further messages do not repeat it.
5. Let the escalation TTL expire, then send a message -> the bot
   answers in a fresh session instead of going silent.

## Risks

- conversation-chat needs a typed "closed" response; check callers of
  `ProcessTurn` do not already treat that path as a hard error.
- The escalation-notice-once logic needs a flag in session state or
  Redis; confirm there is a place to store it without a schema change.
