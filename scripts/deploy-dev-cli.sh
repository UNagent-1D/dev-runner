#!/usr/bin/env bash
# scripts/deploy-dev-cli.sh — One-shot CLI deploy of all data stores +
# app services into the linked Railway project's dev environment.
#
# Idempotent: re-run after fixing any error. Pre-reqs:
#   - `railway link` already done (you're attached to the right project)
#   - `railway environment dev` (script enforces this)
#   - shared variables already uploaded to the dev environment

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # umbrella root

log()  { printf "\033[1;36m▶\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!\033[0m %s\n" "$*" >&2; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$*"; }

railway environment dev >/dev/null
ok "Environment: dev"

# ──────────────────────────────────────────────────────────────────────────
# Service definitions: name|dockerfile|public_domain?|extra_vars (semicolon-separated)
# ──────────────────────────────────────────────────────────────────────────
SERVICES=(
  # Data stores
  "redis|scripts/data-stores/redis.Dockerfile|no|"
  "email-mongo|scripts/data-stores/email-mongo.Dockerfile|no|"
  "conversation-mongo|scripts/data-stores/conversation-mongo.Dockerfile|no|"
  "hospital-postgres|scripts/data-stores/hospital-postgres.Dockerfile|no|POSTGRES_USER=\${{ shared.HOSPITAL_DB_USER }};POSTGRES_PASSWORD=\${{ shared.HOSPITAL_DB_PASSWORD }};POSTGRES_DB=\${{ shared.HOSPITAL_DB_NAME }}"
  "tenant-postgres|scripts/data-stores/tenant-postgres.Dockerfile|no|POSTGRES_USER=\${{ shared.TENANT_DB_USER }};POSTGRES_PASSWORD=\${{ shared.TENANT_DB_PASSWORD }};POSTGRES_DB=\${{ shared.TENANT_DB_NAME }}"
  "rabbitmq|UN_message_broker_mb/Dockerfile|no|"

  # App services
  "tenant|Tenant/Dockerfile|yes|DATABASE_URL=\${{ shared.DATABASE_URL }};JWT_SECRET=\${{ shared.JWT_SECRET }};GIN_MODE=release"
  "hospital-mock|Hospital-MP/Dockerfile|no|DATABASE_URL=postgresql://\${{ shared.HOSPITAL_DB_USER }}:\${{ shared.HOSPITAL_DB_PASSWORD }}@hospital-postgres.railway.internal:5432/\${{ shared.HOSPITAL_DB_NAME }}"
  "agent-runtime|agent-runtime/Dockerfile|no|PORT=3100;CONVERSATION_CHAT_URL=\${{ shared.CONVERSATION_CHAT_URL }};HOSPITAL_MOCK_URL=\${{ shared.HOSPITAL_MOCK_URL }};OPENAI_BASE_URL=\${{ shared.OPENAI_BASE_URL }};OPENAI_DEFAULT_MODEL=\${{ shared.OPENAI_DEFAULT_MODEL }};RABBITMQ_URL=\${{ shared.RABBITMQ_URL }}"
  "conversation-chat|conversation-chat/Dockerfile|yes|SERVER_PORT=8082;GIN_MODE=release;REDIS_URL=\${{ shared.REDIS_URL }};MONGO_URI=\${{ shared.MONGO_URI }};MONGO_DB=\${{ shared.MONGO_DB }};ACR_SERVICE_URL=\${{ shared.ACR_SERVICE_URL }};TENANT_SERVICE_URL=\${{ shared.TENANT_SERVICE_URL }};AUTH_SERVICE_URL=\${{ shared.AUTH_SERVICE_URL }};OPENAI_API_KEY=\${{ shared.OPENROUTER_API_KEY }};OPENAI_BASE_URL=\${{ shared.OPENAI_BASE_URL }};OPENAI_DEFAULT_MODEL=\${{ shared.OPENAI_DEFAULT_MODEL }};AUTH_STUB=true;AUTH_STUB_USER_ID=00000000-0000-0000-0000-000000000001;AUTH_STUB_ROLE=app_admin;AUTH_STUB_EMAIL=internal@platform.local;DEFAULT_IDLE_TIMEOUT_SECONDS=300;RABBITMQ_URL=\${{ shared.RABBITMQ_URL }}"
  "chat-orch|chat-orch/Dockerfile|yes|SERVER_HOST=0.0.0.0;SERVER_PORT=3000;OPENAI_API_KEY=\${{ shared.OPENROUTER_API_KEY }};OPENAI_BASE_URL=\${{ shared.OPENAI_BASE_URL }};OPENAI_DEFAULT_MODEL=\${{ shared.OPENAI_DEFAULT_MODEL }};CONVERSATION_CHAT_URL=\${{ shared.CONVERSATION_CHAT_URL }};TENANT_SERVICE_URL=\${{ shared.TENANT_SERVICE_URL }};METRICAS_URL=\${{ shared.METRICAS_URL }};HOSPITAL_MOCK_URL=\${{ shared.HOSPITAL_MOCK_URL }};AGENT_RUNTIME_URL=\${{ shared.AGENT_RUNTIME_URL }};CORS_ALLOW_ORIGIN=\${{ shared.CORS_ALLOW_ORIGIN }};TELEGRAM_BOT_TOKEN=\${{ shared.TELEGRAM_BOT_TOKEN }};TELEGRAM_DEFAULT_TENANT_ID=\${{ shared.TELEGRAM_DEFAULT_TENANT_ID }};RUST_LOG=chat_orch=info,tower_http=info;LOG_FORMAT=json"
  "compliance|Compliance/Dockerfile|yes|MONGO_URI=\${{ shared.MONGO_URI_COMPLIANCE }};MONGO_DB_COMPLIANCE=\${{ shared.MONGO_DB_COMPLIANCE }}"
  "email-send|UN_email_send_ms/Dockerfile|no|SERVER_PORT=8080;MONGO_URI=\${{ shared.MONGO_URI_COMPLIANCE }};MONGO_DB_EMAIL=\${{ shared.MONGO_DB_EMAIL }};SENDGRID_API_KEY=\${{ shared.SENDGRID_API_KEY }};SENDGRID_SANDBOX_MODE=\${{ shared.SENDGRID_SANDBOX_MODE }};EMAIL_FROM_DEFAULT=\${{ shared.EMAIL_FROM_DEFAULT }};EMAIL_FROM_NAME=\${{ shared.EMAIL_FROM_NAME }};JWT_SECRET=\${{ shared.JWT_SECRET }};AUTH_STUB=\${{ shared.EMAIL_AUTH_STUB }};LOG_FORMAT=json"
)

# ──────────────────────────────────────────────────────────────────────────
# Pass 1: create every service + set its variables (no deploy yet).
# ──────────────────────────────────────────────────────────────────────────
for row in "${SERVICES[@]}"; do
  IFS='|' read -r name dockerfile public extra <<< "$row"
  log "[$name] creating + configuring"

  # Create service. `railway add --service <name>` creates an empty service
  # in the linked project. If it exists, the command errors — we swallow.
  railway add --service "$name" 2>/dev/null || true

  # Tell Railway which Dockerfile to use for THIS service.
  railway variables --service "$name" --set "RAILWAY_DOCKERFILE_PATH=$dockerfile" >/dev/null

  # Set the per-service variables (semicolon-separated KEY=VAL pairs).
  if [ -n "$extra" ]; then
    IFS=';' read -ra pairs <<< "$extra"
    for kv in "${pairs[@]}"; do
      railway variables --service "$name" --set "$kv" >/dev/null
    done
  fi

  # Generate a public domain if the service needs one.
  if [ "$public" = "yes" ]; then
    railway domain --service "$name" >/dev/null 2>&1 || true
  fi
done
ok "All services created + variables set."

# ──────────────────────────────────────────────────────────────────────────
# Pass 2: volume reminders. The CLI's volume support is unreliable across
# versions; show exact dashboard steps for the 6 stateful services.
# ──────────────────────────────────────────────────────────────────────────
cat <<'EOF'

────────────────────────────────────────────────────────────────────
⚠  Volumes still need a dashboard click (CLI gap). For each below:
   Service → Volumes → "+ Add Volume" → Mount path:

   redis              → /data
   email-mongo        → /data/db
   conversation-mongo → /data/db
   hospital-postgres  → /var/lib/postgresql/data
   tenant-postgres    → /var/lib/postgresql/data
   rabbitmq           → /var/lib/rabbitmq

Do this BEFORE deploying — Postgres init scripts run only against an
empty volume, and you want that volume to be the persistent one.
────────────────────────────────────────────────────────────────────
EOF
read -r -p "Press Enter once volumes are attached…"

# ──────────────────────────────────────────────────────────────────────────
# Pass 3: deploy in order. Data stores first; then app services.
# ──────────────────────────────────────────────────────────────────────────
DATA_STORES=(redis email-mongo conversation-mongo hospital-postgres tenant-postgres rabbitmq)
APP_SERVICES=(tenant hospital-mock agent-runtime conversation-chat chat-orch compliance email-send)

for svc in "${DATA_STORES[@]}"; do
  log "[$svc] railway up --detach"
  railway up --service "$svc" --detach
done

ok "Data stores building — wait until all show Active before continuing."
read -r -p "Press Enter once all 6 data stores are green…"

for svc in "${APP_SERVICES[@]}"; do
  log "[$svc] railway up --detach"
  railway up --service "$svc" --detach
done

ok "All services kicked off. Watch the dashboard or run:"
echo "  for s in ${DATA_STORES[*]} ${APP_SERVICES[*]}; do echo \"── \$s ──\"; railway logs --service \"\$s\" | head -20; done"
