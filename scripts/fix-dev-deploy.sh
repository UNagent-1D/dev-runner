#!/usr/bin/env bash
# scripts/fix-dev-deploy.sh — fix the two root causes that broke the first
# deploy and redeploy everything:
#   1. Variables aren't reaching the running containers. The CLI in your
#      version doesn't support `--shared`, so we set RESOLVED values
#      directly on each service (no `${{ shared.X }}` indirection).
#   2. Build context is the umbrella root but submodule Dockerfiles assume
#      their own dir as context. Fixed via RAILWAY_ROOT_DIRECTORY.
#
# Idempotent. Run from the umbrella root with `railway` linked to dev env.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

log()  { printf "\033[1;36m▶\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m✘\033[0m %s\n" "$*" >&2; exit 1; }

[ -f .env.dev ] || err ".env.dev not found; copy from .env.dev.example and fill in."
railway environment dev >/dev/null
ok "Linked to dev environment."

# ──────────────────────────────────────────────────────────────────────────
# Parse .env.dev into an associative array, expanding ${VAR} references
# using earlier values in the file. No `source` — values may contain
# spaces, parens, ampersands, etc.
# ──────────────────────────────────────────────────────────────────────────
declare -A VARS
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; esac
  [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
  key="${BASH_REMATCH[1]}"
  val="${BASH_REMATCH[2]}"
  if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then
    val="${BASH_REMATCH[1]}"
  fi
  while [[ "$val" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
    ref="${BASH_REMATCH[1]}"
    val="${val//\$\{$ref\}/${VARS[$ref]:-}}"
  done
  VARS["$key"]="$val"
done < .env.dev
ok "Parsed $(echo "${#VARS[@]}") keys from .env.dev"

# Convenience: lookup with default-empty.
v() { printf '%s' "${VARS[$1]:-}"; }

# ──────────────────────────────────────────────────────────────────────────
# Per-service variables: service-name → list of "KEY=value" pairs to set.
# Values pull from $(v KEY) so they're resolved literals at this point.
# This replaces the broken `${{ shared.X }}` references.
# ──────────────────────────────────────────────────────────────────────────
set_vars() {
  local svc="$1"; shift
  local args=()
  for kv in "$@"; do args+=(--set "$kv"); done
  railway variables --service "$svc" "${args[@]}" >/dev/null
}

apply_service() {
  local svc="$1" root="$2" dockerfile="$3"; shift 3
  log "[$svc] root=$root dockerfile=$dockerfile + $# vars"
  # Build a clean array of vars; include RAILWAY_* path config first.
  local pairs=( "RAILWAY_ROOT_DIRECTORY=$root" "RAILWAY_DOCKERFILE_PATH=$dockerfile" "$@" )
  set_vars "$svc" "${pairs[@]}"
}

# Data stores (root = umbrella so the schema/seed COPYs work for the
# Postgres custom Dockerfiles).
apply_service redis              "." "scripts/data-stores/redis.Dockerfile"
apply_service email-mongo        "." "scripts/data-stores/email-mongo.Dockerfile"
apply_service conversation-mongo "." "scripts/data-stores/conversation-mongo.Dockerfile"
apply_service hospital-postgres  "." "scripts/data-stores/hospital-postgres.Dockerfile" \
  "POSTGRES_USER=$(v HOSPITAL_DB_USER)" \
  "POSTGRES_PASSWORD=$(v HOSPITAL_DB_PASSWORD)" \
  "POSTGRES_DB=$(v HOSPITAL_DB_NAME)"
apply_service tenant-postgres    "." "scripts/data-stores/tenant-postgres.Dockerfile" \
  "POSTGRES_USER=$(v TENANT_DB_USER)" \
  "POSTGRES_PASSWORD=$(v TENANT_DB_PASSWORD)" \
  "POSTGRES_DB=$(v TENANT_DB_NAME)"
apply_service rabbitmq           "UN_message_broker_mb" "Dockerfile"

# Application services.
apply_service tenant             "Tenant" "Dockerfile" \
  "DATABASE_URL=$(v DATABASE_URL)" \
  "JWT_SECRET=$(v JWT_SECRET)" \
  "GIN_MODE=release"

apply_service hospital-mock      "Hospital-MP" "Dockerfile" \
  "DATABASE_URL=postgresql://$(v HOSPITAL_DB_USER):$(v HOSPITAL_DB_PASSWORD)@hospital-postgres.railway.internal:5432/$(v HOSPITAL_DB_NAME)"

apply_service agent-runtime      "agent-runtime" "Dockerfile" \
  "PORT=3100" \
  "CONVERSATION_CHAT_URL=$(v CONVERSATION_CHAT_URL)" \
  "HOSPITAL_MOCK_URL=$(v HOSPITAL_MOCK_URL)" \
  "OPENAI_BASE_URL=$(v OPENAI_BASE_URL)" \
  "OPENAI_DEFAULT_MODEL=$(v OPENAI_DEFAULT_MODEL)" \
  "RABBITMQ_URL=$(v RABBITMQ_URL)"

apply_service conversation-chat  "conversation-chat" "Dockerfile" \
  "SERVER_PORT=8082" \
  "GIN_MODE=release" \
  "REDIS_URL=$(v REDIS_URL)" \
  "MONGO_URI=$(v MONGO_URI)" \
  "MONGO_DB=$(v MONGO_DB)" \
  "ACR_SERVICE_URL=$(v ACR_SERVICE_URL)" \
  "TENANT_SERVICE_URL=$(v TENANT_SERVICE_URL)" \
  "AUTH_SERVICE_URL=$(v AUTH_SERVICE_URL)" \
  "OPENAI_API_KEY=$(v OPENROUTER_API_KEY)" \
  "OPENAI_BASE_URL=$(v OPENAI_BASE_URL)" \
  "OPENAI_DEFAULT_MODEL=$(v OPENAI_DEFAULT_MODEL)" \
  "AUTH_STUB=true" \
  "AUTH_STUB_USER_ID=00000000-0000-0000-0000-000000000001" \
  "AUTH_STUB_ROLE=app_admin" \
  "AUTH_STUB_EMAIL=internal@platform.local" \
  "DEFAULT_IDLE_TIMEOUT_SECONDS=300" \
  "RABBITMQ_URL=$(v RABBITMQ_URL)"

apply_service chat-orch          "chat-orch" "Dockerfile" \
  "SERVER_HOST=0.0.0.0" \
  "SERVER_PORT=3000" \
  "OPENAI_API_KEY=$(v OPENROUTER_API_KEY)" \
  "OPENAI_BASE_URL=$(v OPENAI_BASE_URL)" \
  "OPENAI_DEFAULT_MODEL=$(v OPENAI_DEFAULT_MODEL)" \
  "CONVERSATION_CHAT_URL=$(v CONVERSATION_CHAT_URL)" \
  "TENANT_SERVICE_URL=$(v TENANT_SERVICE_URL)" \
  "METRICAS_URL=$(v METRICAS_URL)" \
  "HOSPITAL_MOCK_URL=$(v HOSPITAL_MOCK_URL)" \
  "AGENT_RUNTIME_URL=$(v AGENT_RUNTIME_URL)" \
  "CORS_ALLOW_ORIGIN=$(v CORS_ALLOW_ORIGIN)" \
  "TELEGRAM_BOT_TOKEN=$(v TELEGRAM_BOT_TOKEN)" \
  "TELEGRAM_DEFAULT_TENANT_ID=$(v TELEGRAM_DEFAULT_TENANT_ID)" \
  "RUST_LOG=chat_orch=info,tower_http=info" \
  "LOG_FORMAT=json"

apply_service compliance         "Compliance" "Dockerfile" \
  "MONGO_URI=$(v MONGO_URI_COMPLIANCE)" \
  "MONGO_DB_COMPLIANCE=$(v MONGO_DB_COMPLIANCE)"

apply_service email-send         "UN_email_send_ms" "Dockerfile" \
  "SERVER_PORT=8080" \
  "MONGO_URI=$(v MONGO_URI_COMPLIANCE)" \
  "MONGO_DB_EMAIL=$(v MONGO_DB_EMAIL)" \
  "SENDGRID_API_KEY=$(v SENDGRID_API_KEY)" \
  "SENDGRID_SANDBOX_MODE=$(v SENDGRID_SANDBOX_MODE)" \
  "EMAIL_FROM_DEFAULT=$(v EMAIL_FROM_DEFAULT)" \
  "EMAIL_FROM_NAME=$(v EMAIL_FROM_NAME)" \
  "JWT_SECRET=$(v JWT_SECRET)" \
  "AUTH_STUB=$(v EMAIL_AUTH_STUB)" \
  "LOG_FORMAT=json"

ok "All service variables set with resolved values."

# ──────────────────────────────────────────────────────────────────────────
# Redeploy. Data stores first; app services second.
# ──────────────────────────────────────────────────────────────────────────
DATA_STORES=(redis email-mongo conversation-mongo hospital-postgres tenant-postgres rabbitmq)
APP_SERVICES=(tenant hospital-mock agent-runtime conversation-chat chat-orch compliance email-send)

for svc in "${DATA_STORES[@]}"; do
  log "[$svc] railway up --detach"
  railway up --service "$svc" --detach
done

ok "Data stores re-deploying. Wait for tenant-postgres + hospital-postgres to show Active."
read -r -p "Press Enter once all 6 data stores are green…"

for svc in "${APP_SERVICES[@]}"; do
  log "[$svc] railway up --detach"
  railway up --service "$svc" --detach
done

ok "All services re-deploying. Watch the dashboard."
