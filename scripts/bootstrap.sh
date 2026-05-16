#!/usr/bin/env bash
# scripts/bootstrap.sh — one-shot setup for Railway (backends + data stores)
# and Cloudflare (gateway Worker + custom domain).
#
# Idempotent. Run once after first checkout; safe to re-run. Subsequent
# changes ship via `git push` only.
#
# Usage:
#   scripts/bootstrap.sh                # full bootstrap
#   scripts/bootstrap.sh --sync-env     # re-push .env.{dev,prod} to Railway
#                                       # shared vars only, skip everything else
#   scripts/bootstrap.sh --env dev      # bootstrap a single environment
#
# Requirements (all already installed on this machine, per CLAUDE.md):
#   - bash 4+, jq, curl
#   - railway CLI (https://docs.railway.com/guides/cli)
#   - wrangler (Cloudflare Workers CLI)
#   - npm
#
# What this script does NOT do:
#   - Mint Cloudflare API tokens (do that manually in the Cloudflare dashboard
#     once, then paste into GitHub secrets — instructions printed at the end).
#   - Migrate data from Supabase/Atlas (see plan §7.6).

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────
# Constants
# ──────────────────────────────────────────────────────────────────────────
PROJECT_NAME="unagent"
ENVIRONMENTS=("dev" "prod")
APP_SERVICES=(
  "chat-orch:chat-orch/Dockerfile"
  "tenant:Tenant/Dockerfile"
  "conversation-chat:conversation-chat/Dockerfile"
  "agent-runtime:agent-runtime/Dockerfile"
  "hospital-mock:Hospital-MP/Dockerfile"
  "compliance:Compliance/Dockerfile"
  "email-send:UN_email_send_ms/Dockerfile"
  "message-broker:UN_message_broker_mb/Dockerfile"
)
# Services that need a public *.up.railway.app URL (the Cloudflare Worker
# calls them from the edge). The other 4 stay on Railway's private network.
PUBLIC_SERVICES=("chat-orch" "tenant" "conversation-chat" "compliance")

# Data stores: name, source (image: or dockerfile:), volume mount path.
DATA_STORES=(
  "redis|image:redis:7-alpine|/data"
  "email-mongo|image:mongo:7|/data/db"
  "conversation-mongo|image:mongo:7|/data/db"
  "hospital-postgres|dockerfile:scripts/data-stores/hospital-postgres.Dockerfile|/var/lib/postgresql/data"
  "tenant-postgres|dockerfile:scripts/data-stores/tenant-postgres.Dockerfile|/var/lib/postgresql/data"
  "rabbitmq|dockerfile:UN_message_broker_mb/Dockerfile|/var/lib/rabbitmq"
)

# Per-service env keys (these are the keys each app service references from
# `${{ shared.KEY }}`). The bootstrap reads .env.<env> for the values; this
# map says which subset each service consumes.
declare -A SERVICE_VARS=(
  ["chat-orch"]="OPENROUTER_API_KEY OPENAI_BASE_URL OPENAI_DEFAULT_MODEL CONVERSATION_CHAT_URL TENANT_SERVICE_URL METRICAS_URL HOSPITAL_MOCK_URL AGENT_RUNTIME_URL CORS_ALLOW_ORIGIN TELEGRAM_BOT_TOKEN TELEGRAM_DEFAULT_TENANT_ID TWILIO_ACCOUNT_SID TWILIO_AUTH_TOKEN TWILIO_API_KEY_SID TWILIO_API_KEY_SECRET TWILIO_TWIML_APP_SID TWILIO_DEFAULT_TENANT_ID"
  ["tenant"]="DATABASE_URL JWT_SECRET"
  ["conversation-chat"]="MONGO_URI MONGO_DB REDIS_URL RABBITMQ_URL ACR_SERVICE_URL TENANT_SERVICE_URL AUTH_SERVICE_URL OPENROUTER_API_KEY OPENAI_BASE_URL OPENAI_DEFAULT_MODEL"
  ["agent-runtime"]="CONVERSATION_CHAT_URL HOSPITAL_MOCK_URL OPENAI_BASE_URL OPENAI_DEFAULT_MODEL RABBITMQ_URL"
  ["hospital-mock"]="TENANT_DB_USER TENANT_DB_PASSWORD HOSPITAL_DB_USER HOSPITAL_DB_PASSWORD HOSPITAL_DB_NAME"
  ["compliance"]="MONGO_URI_COMPLIANCE MONGO_DB_COMPLIANCE"
  ["email-send"]="MONGO_URI_COMPLIANCE MONGO_DB_EMAIL SENDGRID_API_KEY SENDGRID_SANDBOX_MODE EMAIL_FROM_DEFAULT EMAIL_FROM_NAME JWT_SECRET EMAIL_AUTH_STUB"
  ["message-broker"]=""
)

# Internal service ports (informational — Railway detects via Dockerfile EXPOSE).
declare -A SERVICE_PORTS=(
  ["chat-orch"]="3000"
  ["tenant"]="8080"
  ["conversation-chat"]="8082"
  ["agent-runtime"]="3100"
  ["hospital-mock"]="8080"
  ["compliance"]="8091"
  ["email-send"]="8080"
  ["message-broker"]="5672"
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ──────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────
log()  { printf "\033[1;36m▶\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m✘\033[0m %s\n" "$*" >&2; exit 1; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "missing required command: $1"
}

# Read a key from a .env file, expanding ${VAR} references using values from
# the same file. Returns empty string if the key isn't present.
read_env_var() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  # Source the file in a subshell so we don't pollute the caller, then echo.
  ( set -a; . "$file"; set +a; echo "${!key:-}" )
}

# List all KEY=VALUE pairs from a .env file (after `${VAR}` expansion).
list_env_vars() {
  local file="$1"
  [ -f "$file" ] || return 0
  # Run in subshell, then `env` shows only the vars we set.
  (
    set -a
    . "$file"
    set +a
    grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$file" \
      | sed 's/=.*//' \
      | while read -r key; do
          val="${!key:-}"
          printf '%s=%s\n' "$key" "$val"
        done
  )
}

# Run a railway CLI command, but tolerate "already exists" / 409 errors so
# the script remains idempotent. Pass --idempotent before the args.
railway_idempotent() {
  if ! out="$(railway "$@" 2>&1)"; then
    case "$out" in
      *"already exists"*|*"AlreadyExists"*|*"409"*|*"duplicate"*)
        warn "  (skipped — already exists)"
        return 0
        ;;
      *)
        err "railway $* failed: $out"
        ;;
    esac
  fi
  printf '%s\n' "$out"
}

# ──────────────────────────────────────────────────────────────────────────
# Arg parsing
# ──────────────────────────────────────────────────────────────────────────
MODE="full"
TARGET_ENV=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sync-env) MODE="sync-env"; shift ;;
    --env)      TARGET_ENV="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *) err "unknown arg: $1" ;;
  esac
done

if [ -n "$TARGET_ENV" ]; then
  ENVIRONMENTS=("$TARGET_ENV")
fi

require_cmd railway
require_cmd jq
require_cmd curl

# ──────────────────────────────────────────────────────────────────────────
# Validate .env files exist for the environments we plan to bootstrap.
# ──────────────────────────────────────────────────────────────────────────
for env in "${ENVIRONMENTS[@]}"; do
  if [ ! -f ".env.$env" ]; then
    err ".env.$env not found. Copy .env.$env.example to .env.$env and fill it in."
  fi
done

# ──────────────────────────────────────────────────────────────────────────
# Railway login + project init (idempotent)
# ──────────────────────────────────────────────────────────────────────────
if ! railway whoami >/dev/null 2>&1; then
  log "Logging into Railway (interactive — only the first time)…"
  railway login
fi
ok "Logged in to Railway as $(railway whoami | head -n 1)"

if [ ! -f ".railway/config.json" ] && [ -z "${RAILWAY_PROJECT_ID:-}" ]; then
  log "Linking project $PROJECT_NAME (creating if missing)…"
  if ! railway link --project "$PROJECT_NAME" 2>/dev/null; then
    railway init --name "$PROJECT_NAME"
  fi
fi
ok "Project linked: $PROJECT_NAME"

# ──────────────────────────────────────────────────────────────────────────
# Sync-env mode: push .env.<env> to Railway shared vars and stop.
# ──────────────────────────────────────────────────────────────────────────
sync_shared_vars() {
  local env="$1"
  log "Syncing .env.$env → Railway shared variables (environment=$env)"
  while IFS='=' read -r key val; do
    [ -z "$key" ] && continue
    # The Railway CLI's `variables --set` writes to the *currently-linked
    # service*; for shared vars (no service), we use the GraphQL API path.
    # The CLI gained `variables --shared` in v3.18 — prefer that, fall back
    # to GraphQL if the local CLI is older.
    if railway variables --help 2>&1 | grep -q -- "--shared"; then
      railway variables --shared --environment "$env" --set "$key=$val" >/dev/null
    else
      warn "Older Railway CLI: shared-var sync via GraphQL not yet wired. Upgrade to v3.18+."
      return 1
    fi
  done < <(list_env_vars ".env.$env")
  ok "Shared vars synced for $env"
}

if [ "$MODE" = "sync-env" ]; then
  for env in "${ENVIRONMENTS[@]}"; do sync_shared_vars "$env"; done
  ok "Sync complete. No services were touched."
  exit 0
fi

# ──────────────────────────────────────────────────────────────────────────
# Per-environment bootstrap
# ──────────────────────────────────────────────────────────────────────────
for env in "${ENVIRONMENTS[@]}"; do
  log "═══ Environment: $env ═══"

  # Create the environment (skips if exists).
  log "  Ensuring environment exists…"
  railway_idempotent environment new "$env" || true
  railway environment "$env" >/dev/null

  # Upload .env.<env> as shared variables.
  sync_shared_vars "$env"

  # Data stores first (so app services can resolve internal hostnames).
  log "  Creating data-store services…"
  for spec in "${DATA_STORES[@]}"; do
    IFS='|' read -r ds_name ds_source ds_mount <<< "$spec"
    log "    • $ds_name ($ds_source)"
    railway_idempotent service create --name "$ds_name" --environment "$env" || true

    case "$ds_source" in
      image:*)
        img="${ds_source#image:}"
        # Set the image source via GraphQL — CLI doesn't expose this directly.
        # See scripts/bootstrap.md for the API token setup.
        warn "      Set image '$img' + volume '$ds_mount' via Railway dashboard"
        warn "      (or via Railway GraphQL — see bootstrap.md §3)"
        ;;
      dockerfile:*)
        df="${ds_source#dockerfile:}"
        warn "      Set Dockerfile path '$df' + volume '$ds_mount' via Railway dashboard"
        ;;
    esac
  done

  # Then the application services.
  log "  Creating application services…"
  for spec in "${APP_SERVICES[@]}"; do
    IFS=':' read -r svc dockerfile <<< "$spec"
    log "    • $svc ($dockerfile)"
    railway_idempotent service create --name "$svc" --environment "$env" || true
    warn "      Set Dockerfile path '$dockerfile' + root '/' via Railway dashboard"

    # Wire per-service variables to ${{ shared.* }} references.
    keys="${SERVICE_VARS[$svc]:-}"
    if [ -n "$keys" ]; then
      for key in $keys; do
        ref='${{ shared.'"$key"' }}'
        railway variables --service "$svc" --environment "$env" \
          --set "$key=$ref" >/dev/null 2>&1 || true
      done
    fi
  done

  # Generate public domains for the 4 Worker-facing services.
  log "  Generating public domains for Worker-facing services…"
  for svc in "${PUBLIC_SERVICES[@]}"; do
    railway domain --service "$svc" --environment "$env" >/dev/null 2>&1 || true
    url="$(railway domain --service "$svc" --environment "$env" --json 2>/dev/null \
            | jq -r '.[0].domain' 2>/dev/null || echo "")"
    if [ -n "$url" ] && [ "$url" != "null" ]; then
      ok "    $svc → https://$url"
    else
      warn "    $svc → check Railway dashboard for the public URL"
    fi
  done
done

# ──────────────────────────────────────────────────────────────────────────
# Cloudflare Worker — substitute template + deploy
# ──────────────────────────────────────────────────────────────────────────
log "═══ Cloudflare Worker ═══"

if ! command -v wrangler >/dev/null 2>&1; then
  warn "wrangler not installed globally — falling back to npx wrangler."
  WRANGLER="npx wrangler"
else
  WRANGLER="wrangler"
fi

read -r -p "Apex domain (e.g. unagent.example.com): " APEX
if [ -z "$APEX" ]; then err "Apex domain is required."; fi

log "  Rendering wrangler.toml from template…"
template="cloudflare-worker/wrangler.toml.template"
output="cloudflare-worker/wrangler.toml"
cp "$template" "$output"

# Substitute the apex first, then ask the user for each backend URL (or
# capture from `railway domain` output above — kept manual here so this
# script works even if the CLI returns nothing).
sed -i "s|{{APEX}}|$APEX|g" "$output"

for env in "${ENVIRONMENTS[@]}"; do
  E=$(echo "$env" | tr '[:lower:]' '[:upper:]')
  for svc in "${PUBLIC_SERVICES[@]}"; do
    var_name="BACKEND_$(echo "$svc" | tr '[a-z]-' '[A-Z]_')_$E"
    placeholder="{{${var_name}}}"
    read -r -p "  ${var_name} (public Railway URL for $svc in $env): " val
    sed -i "s|$placeholder|$val|g" "$output"
  done
done
ok "  wrangler.toml ready."

log "  Installing Worker dependencies…"
( cd cloudflare-worker && npm ci ) >/dev/null

log "  Building FrontEnd (Vite)…"
( cd FrontEnd && npm ci && npm run build ) >/dev/null

for env in "${ENVIRONMENTS[@]}"; do
  log "  Deploying Worker (env=$env)…"
  ( cd cloudflare-worker && $WRANGLER deploy --env "$env" )
done

# ──────────────────────────────────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────────────────────────────────
log "═══ GitHub secrets to set ═══"
cat <<EOF

Paste the following into GitHub → Settings → Secrets and variables → Actions:

  RAILWAY_TOKEN_DEV       — mint at https://railway.com/account/tokens
                            (scope: project '$PROJECT_NAME', environment 'dev')
  RAILWAY_TOKEN_PROD      — same, scope 'prod'
  CLOUDFLARE_API_TOKEN    — Cloudflare → My Profile → API Tokens → Create.
                            Template: "Edit Cloudflare Workers". Account scope.
  CLOUDFLARE_ACCOUNT_ID   — Cloudflare dashboard → right sidebar of any zone.
  SUBMODULES_TOKEN        — GitHub fine-grained PAT (repo:read on UNagent-1D).

Then push to 'dev' to trigger your first deploy via GitHub Actions.

EOF
ok "Bootstrap complete."
