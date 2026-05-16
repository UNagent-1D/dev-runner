#!/usr/bin/env bash
# scripts/setup-prod.sh — one-shot prod environment cutover, with every
# correction we discovered during the dev bootstrap pre-applied.
#
# What this does, in order:
#   1. Looks up the prod environment ID via Railway's GraphQL API.
#   2. Creates all 13 services in prod (6 data stores + 7 apps).
#   3. Sets Service → Root Directory + Dockerfile Path via GraphQL (so the
#      build context is correct from the first deploy).
#   4. Sets per-service env vars from .env.prod, with these corrections:
#        - rabbitmq:        RABBITMQ_DEFAULT_USER=guest, _PASS=guest
#                           (creates the guest user on first boot — no SSH dance)
#        - compliance:      PORT=8091
#        - chat-orch:       PORT=3000
#        - conversation-chat: TENANT_SERVICE_URL → agent-runtime (not Tenant)
#        - Mongo URIs:      no auth (matches dev)
#   5. Generates public domains for the 4 Worker-facing services.
#   6. Sets GH repo variables RAILWAY_PROD_*_URL from those domains.
#   7. Substitutes prod URLs into cloudflare-worker/wrangler.toml.
#   8. PAUSES for you to attach volumes in the dashboard (only manual step).
#   9. `railway up` each service.
#   10. `wrangler deploy --env prod` → binds apex `unagent.site`.
#   11. Smoke-tests https://unagent.site/.
#
# Requires:
#   - RAILWAY_API_TOKEN env var (account token from
#     https://railway.com/account/tokens) — needed for GraphQL.
#   - RAILWAY_TOKEN env var OR `railway link` already done (CLI auth).
#   - gh CLI authenticated.
#   - .env.prod populated with real values.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
UMBRELLA="$(pwd)"

PROJECT_ID="3d5be088-15a5-4763-8bf1-6332dfd44fd9"
APEX="unagent.site"
REPO="UNagent-1D/dev-runner"
ENDPOINT="${RAILWAY_GRAPHQL_ENDPOINT:-https://backboard.railway.app/graphql/v2}"

log()  { printf "\033[1;36m▶\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m✘\033[0m %s\n" "$*" >&2; exit 1; }

: "${RAILWAY_API_TOKEN:?Set RAILWAY_API_TOKEN (https://railway.com/account/tokens)}"
command -v railway >/dev/null || err "railway CLI not installed"
command -v jq      >/dev/null || err "jq not installed"
command -v gh      >/dev/null || err "gh CLI not installed"
[ -f .env.prod ]              || err ".env.prod not found"

gql() {
  local query="$1"
  local vars="${2:-{\}}"
  curl -sS -X POST "$ENDPOINT" \
    -H "Authorization: Bearer $RAILWAY_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg q "$query" --argjson v "$vars" '{query:$q, variables:$v}')"
}

# ──────────────────────────────────────────────────────────────────────────
# 1. Parse .env.prod into a map (no shell sourcing → handles parens/spaces).
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
done < .env.prod
v() { printf '%s' "${VARS[$1]:-}"; }
ok "Parsed ${#VARS[@]} keys from .env.prod"

# ──────────────────────────────────────────────────────────────────────────
# 2. Look up prod environment ID.
# ──────────────────────────────────────────────────────────────────────────
log "Fetching prod environment ID…"
ENV_RES=$(gql 'query($id: String!){ project(id:$id){ environments{ edges{ node{ id name } } } } }' \
              "$(jq -nc --arg id "$PROJECT_ID" '{id:$id}')")
PROD_ENV_ID=$(echo "$ENV_RES" | jq -r '.data.project.environments.edges[] | select(.node.name=="Production") | .node.id' | head -1)
[ -n "$PROD_ENV_ID" ] || err "Production environment not found. Create it: railway environment new Production"
ok "Production env ID: $PROD_ENV_ID"

railway environment Production >/dev/null
ok "CLI linked to Production"

# ──────────────────────────────────────────────────────────────────────────
# 3. Service definitions. Mirrors what worked in dev.
#    name | root_dir | dockerfile_path | extra_vars (newline-separated KEY=VAL)
# ──────────────────────────────────────────────────────────────────────────
# data stores
DS_REDIS_DF=scripts/data-stores/redis.Dockerfile
DS_EMAIL_MONGO_DF=scripts/data-stores/email-mongo.Dockerfile
DS_CONV_MONGO_DF=scripts/data-stores/conversation-mongo.Dockerfile
DS_HOSPITAL_PG_DF=scripts/data-stores/hospital-postgres.Dockerfile
DS_TENANT_PG_DF=scripts/data-stores/tenant-postgres.Dockerfile

declare -A SVC_ROOT SVC_DF SVC_VARS

# data stores
SVC_ROOT[redis]="." ; SVC_DF[redis]="$DS_REDIS_DF" ; SVC_VARS[redis]=""
SVC_ROOT[email-mongo]="." ; SVC_DF[email-mongo]="$DS_EMAIL_MONGO_DF" ; SVC_VARS[email-mongo]=""
SVC_ROOT[conversation-mongo]="." ; SVC_DF[conversation-mongo]="$DS_CONV_MONGO_DF" ; SVC_VARS[conversation-mongo]=""

SVC_ROOT[hospital-postgres]="."
SVC_DF[hospital-postgres]="$DS_HOSPITAL_PG_DF"
SVC_VARS[hospital-postgres]="POSTGRES_USER=$(v HOSPITAL_DB_USER)
POSTGRES_PASSWORD=$(v HOSPITAL_DB_PASSWORD)
POSTGRES_DB=$(v HOSPITAL_DB_NAME)"

SVC_ROOT[tenant-postgres]="."
SVC_DF[tenant-postgres]="$DS_TENANT_PG_DF"
SVC_VARS[tenant-postgres]="POSTGRES_USER=$(v TENANT_DB_USER)
POSTGRES_PASSWORD=$(v TENANT_DB_PASSWORD)
POSTGRES_DB=$(v TENANT_DB_NAME)"

# rabbitmq: bake guest:guest creds via DEFAULT_USER/PASS so no SSH dance needed
SVC_ROOT[rabbitmq]="UN_message_broker_mb"
SVC_DF[rabbitmq]="Dockerfile"
SVC_VARS[rabbitmq]="RABBITMQ_DEFAULT_USER=guest
RABBITMQ_DEFAULT_PASS=guest"

# app services
SVC_ROOT[tenant]="Tenant"
SVC_DF[tenant]="Dockerfile"
SVC_VARS[tenant]="DATABASE_URL=$(v DATABASE_URL)
JWT_SECRET=$(v JWT_SECRET)
GIN_MODE=release"

SVC_ROOT[hospital-mock]="Hospital-MP"
SVC_DF[hospital-mock]="Dockerfile"
SVC_VARS[hospital-mock]="DATABASE_URL=postgresql://$(v HOSPITAL_DB_USER):$(v HOSPITAL_DB_PASSWORD)@hospital-postgres.railway.internal:5432/$(v HOSPITAL_DB_NAME)"

SVC_ROOT[agent-runtime]="agent-runtime"
SVC_DF[agent-runtime]="Dockerfile"
SVC_VARS[agent-runtime]="PORT=3100
CONVERSATION_CHAT_URL=$(v CONVERSATION_CHAT_URL)
HOSPITAL_MOCK_URL=$(v HOSPITAL_MOCK_URL)
OPENAI_BASE_URL=$(v OPENAI_BASE_URL)
OPENAI_DEFAULT_MODEL=$(v OPENAI_DEFAULT_MODEL)
RABBITMQ_URL=amqp://guest:guest@rabbitmq.railway.internal:5672"

SVC_ROOT[conversation-chat]="conversation-chat"
SVC_DF[conversation-chat]="Dockerfile"
# Note: TENANT_SERVICE_URL → agent-runtime, NOT real tenant (that's the bug we hit in dev)
SVC_VARS[conversation-chat]="SERVER_PORT=8082
GIN_MODE=release
REDIS_URL=redis://redis.railway.internal:6379/1
MONGO_URI=mongodb://conversation-mongo.railway.internal:27017
MONGO_DB=$(v MONGO_DB)
ACR_SERVICE_URL=http://agent-runtime.railway.internal:3100
TENANT_SERVICE_URL=http://agent-runtime.railway.internal:3100
AUTH_SERVICE_URL=$(v AUTH_SERVICE_URL)
OPENAI_API_KEY=$(v OPENROUTER_API_KEY)
OPENAI_BASE_URL=$(v OPENAI_BASE_URL)
OPENAI_DEFAULT_MODEL=$(v OPENAI_DEFAULT_MODEL)
AUTH_STUB=true
AUTH_STUB_USER_ID=00000000-0000-0000-0000-000000000001
AUTH_STUB_ROLE=app_admin
AUTH_STUB_EMAIL=internal@platform.local
DEFAULT_IDLE_TIMEOUT_SECONDS=300
RABBITMQ_URL=amqp://guest:guest@rabbitmq.railway.internal:5672"

SVC_ROOT[chat-orch]="chat-orch"
SVC_DF[chat-orch]="Dockerfile"
SVC_VARS[chat-orch]="PORT=3000
SERVER_HOST=0.0.0.0
SERVER_PORT=3000
OPENAI_API_KEY=$(v OPENROUTER_API_KEY)
OPENAI_BASE_URL=$(v OPENAI_BASE_URL)
OPENAI_DEFAULT_MODEL=$(v OPENAI_DEFAULT_MODEL)
CONVERSATION_CHAT_URL=$(v CONVERSATION_CHAT_URL)
TENANT_SERVICE_URL=$(v TENANT_SERVICE_URL)
METRICAS_URL=$(v METRICAS_URL)
HOSPITAL_MOCK_URL=$(v HOSPITAL_MOCK_URL)
AGENT_RUNTIME_URL=$(v AGENT_RUNTIME_URL)
CORS_ALLOW_ORIGIN=$(v CORS_ALLOW_ORIGIN)
TELEGRAM_BOT_TOKEN=$(v TELEGRAM_BOT_TOKEN)
TELEGRAM_DEFAULT_TENANT_ID=$(v TELEGRAM_DEFAULT_TENANT_ID)
RUST_LOG=chat_orch=info,tower_http=info
LOG_FORMAT=json"

SVC_ROOT[compliance]="Compliance"
SVC_DF[compliance]="Dockerfile"
SVC_VARS[compliance]="PORT=8091
MONGO_URI=mongodb://email-mongo.railway.internal:27017
MONGO_DB_COMPLIANCE=$(v MONGO_DB_COMPLIANCE)"

SVC_ROOT[email-send]="UN_email_send_ms"
SVC_DF[email-send]="Dockerfile"
SVC_VARS[email-send]="SERVER_PORT=8080
MONGO_URI=mongodb://email-mongo.railway.internal:27017
MONGO_DB_EMAIL=$(v MONGO_DB_EMAIL)
SENDGRID_API_KEY=$(v SENDGRID_API_KEY)
SENDGRID_SANDBOX_MODE=$(v SENDGRID_SANDBOX_MODE)
EMAIL_FROM_DEFAULT=$(v EMAIL_FROM_DEFAULT)
EMAIL_FROM_NAME=$(v EMAIL_FROM_NAME)
JWT_SECRET=$(v JWT_SECRET)
AUTH_STUB=$(v EMAIL_AUTH_STUB)
LOG_FORMAT=json"

DATA_STORES=(redis email-mongo conversation-mongo hospital-postgres tenant-postgres rabbitmq)
APP_SERVICES=(tenant hospital-mock agent-runtime conversation-chat chat-orch compliance email-send)
PUBLIC_SERVICES=(chat-orch tenant conversation-chat compliance)
ALL=("${DATA_STORES[@]}" "${APP_SERVICES[@]}")

# ──────────────────────────────────────────────────────────────────────────
# 4. Create services (idempotent — `railway add` errors if exists, swallow).
# ──────────────────────────────────────────────────────────────────────────
log "Creating services…"
for svc in "${ALL[@]}"; do
  railway add --service "$svc" 2>/dev/null || true
  printf "  %s\n" "$svc"
done

# ──────────────────────────────────────────────────────────────────────────
# 5. Fetch service IDs (needed for GraphQL setRootDir).
# ──────────────────────────────────────────────────────────────────────────
log "Fetching service IDs…"
SVC_LIST=$(gql 'query($id: String!){ project(id:$id){ services{ edges{ node{ id name } } } } }' \
               "$(jq -nc --arg id "$PROJECT_ID" '{id:$id}')")
declare -A SVC_ID
while IFS=$'\t' read -r name id; do
  SVC_ID["$name"]="$id"
done < <(echo "$SVC_LIST" | jq -r '.data.project.services.edges[] | .node | [.name, .id] | @tsv')

# ──────────────────────────────────────────────────────────────────────────
# 6. Set rootDirectory + dockerfilePath per service via GraphQL.
# ──────────────────────────────────────────────────────────────────────────
log "Setting Root Directory + Dockerfile Path per service…"
UPDATE_Q='mutation($id: String!, $env: String!, $input: ServiceInstanceUpdateInput!){
  serviceInstanceUpdate(serviceId:$id, environmentId:$env, input:$input)
}'
for svc in "${ALL[@]}"; do
  sid="${SVC_ID[$svc]:-}"
  [ -z "$sid" ] && { warn "  service $svc not found in API list — skipping"; continue; }
  root="${SVC_ROOT[$svc]}"
  df="${SVC_DF[$svc]}"
  vars=$(jq -nc --arg id "$sid" --arg env "$PROD_ENV_ID" --arg root "$root" --arg df "$df" \
    '{id:$id, env:$env, input:{rootDirectory:$root, dockerfilePath:$df}}')
  res=$(gql "$UPDATE_Q" "$vars")
  if echo "$res" | jq -e '.errors' >/dev/null 2>&1; then
    warn "  $svc — GraphQL error:"
    echo "$res" | jq .errors
  else
    printf "  \033[1;32m✓\033[0m %-22s root=%s dockerfile=%s\n" "$svc" "$root" "$df"
  fi
done

# ──────────────────────────────────────────────────────────────────────────
# 7. Set per-service env vars.
# ──────────────────────────────────────────────────────────────────────────
log "Setting per-service env vars…"
for svc in "${ALL[@]}"; do
  raw="${SVC_VARS[$svc]:-}"
  [ -z "$raw" ] && { printf "  %s (no extra vars)\n" "$svc"; continue; }
  args=()
  while IFS= read -r kv; do
    [ -z "$kv" ] && continue
    args+=(--set "$kv")
  done <<< "$raw"
  railway variables --service "$svc" --environment Production "${args[@]}" >/dev/null
  printf "  \033[1;32m✓\033[0m %s (%d vars)\n" "$svc" "${#args[@]}"
done

# ──────────────────────────────────────────────────────────────────────────
# 8. Generate public domains for the 4 Worker-facing services.
# ──────────────────────────────────────────────────────────────────────────
log "Generating public domains…"
for svc in "${PUBLIC_SERVICES[@]}"; do
  railway domain --service "$svc" --environment Production >/dev/null 2>&1 || true
  printf "  %s\n" "$svc"
done

# ──────────────────────────────────────────────────────────────────────────
# 9. Volume attachment pause (only manual step left).
# ──────────────────────────────────────────────────────────────────────────
cat <<'EOF'

────────────────────────────────────────────────────────────────────
⚠  Attach volumes in the Railway dashboard (one-time manual step).
   Project → prod environment → each service → Volumes → Add Volume.

   redis              → /data
   email-mongo        → /data/db
   conversation-mongo → /data/db
   hospital-postgres  → /var/lib/postgresql/data
   tenant-postgres    → /var/lib/postgresql/data
   rabbitmq           → /var/lib/rabbitmq

   Postgres + RabbitMQ MUST have the volume before first boot so the
   init scripts / DEFAULT_USER credentials persist correctly.
────────────────────────────────────────────────────────────────────
EOF
read -r -p "Press Enter once all 6 volumes are attached…"

# ──────────────────────────────────────────────────────────────────────────
# 10. Deploy each service. Data stores first, app services second.
# ──────────────────────────────────────────────────────────────────────────
log "Deploying data stores…"
for svc in "${DATA_STORES[@]}"; do
  log "[$svc] railway up --detach"
  ( cd "$UMBRELLA" && railway up --service "$svc" --environment Production --detach )
done

ok "Data stores building. Wait for all to show Active before app services."
read -r -p "Press Enter once all 6 data stores are green in the dashboard…"

log "Deploying app services…"
for svc in "${APP_SERVICES[@]}"; do
  log "[$svc] railway up --detach"
  ( cd "$UMBRELLA" && railway up --service "$svc" --environment Production --detach )
done

ok "App services building. Wait for all to show Active."
read -r -p "Press Enter once all 7 app services are green…"

# ──────────────────────────────────────────────────────────────────────────
# 11. Capture public URLs + push to GH variables.
# ──────────────────────────────────────────────────────────────────────────
log "Capturing public URLs + pushing to GH repo variables…"
declare -A URL
for svc in "${PUBLIC_SERVICES[@]}"; do
  out=$(railway domain --service "$svc" --environment Production --json 2>/dev/null || echo "{}")
  url=$(printf '%s' "$out" | jq -r 'first(.. | objects | (.domain? // .host? // empty) | select(type=="string" and length>0)) // empty')
  if [ -z "$url" ]; then
    out=$(railway domain --service "$svc" --environment Production 2>/dev/null || true)
    url=$(printf '%s' "$out" | grep -oE 'https?://[A-Za-z0-9.-]+\.up\.railway\.app' | head -1 | sed 's|https\?://||')
  fi
  if [ -z "$url" ]; then
    warn "  [$svc] no public domain — skipping"
    continue
  fi
  URL["$svc"]="https://$url"
  printf "  %s = https://%s\n" "$svc" "$url"
done

set_gh_var() {
  local name="$1" value="$2"
  [ -z "$value" ] && return
  gh variable set "$name" --body "$value" --repo "$REPO" >/dev/null
}
set_gh_var RAILWAY_PROD_ORCH_URL       "${URL[chat-orch]:-}"
set_gh_var RAILWAY_PROD_TENANT_URL     "${URL[tenant]:-}"
set_gh_var RAILWAY_PROD_CHAT_URL       "${URL[conversation-chat]:-}"
set_gh_var RAILWAY_PROD_COMPLIANCE_URL "${URL[compliance]:-}"
ok "GH repo variables updated."

# ──────────────────────────────────────────────────────────────────────────
# 12. Substitute prod URLs into wrangler.toml + deploy Worker to prod.
# ──────────────────────────────────────────────────────────────────────────
log "Patching cloudflare-worker/wrangler.toml prod block…"
WT="cloudflare-worker/wrangler.toml"

sed -i -E "/^\[env\.prod\.vars\]/,/^\[/{
  s#^BACKEND_ORCH[[:space:]]+=[[:space:]]+\".*\"#BACKEND_ORCH       = \"${URL[chat-orch]:-https://placeholder.invalid}\"#
  s#^BACKEND_TENANT[[:space:]]+=[[:space:]]+\".*\"#BACKEND_TENANT     = \"${URL[tenant]:-https://placeholder.invalid}\"#
  s#^BACKEND_CHAT[[:space:]]+=[[:space:]]+\".*\"#BACKEND_CHAT       = \"${URL[conversation-chat]:-https://placeholder.invalid}\"#
  s#^BACKEND_COMPLIANCE[[:space:]]+=[[:space:]]+\".*\"#BACKEND_COMPLIANCE = \"${URL[compliance]:-https://placeholder.invalid}\"#
}" "$WT"

grep -A 7 '^\[env.prod' "$WT" | head -8

log "Deploying Worker to prod…"
( cd cloudflare-worker && npx wrangler deploy --env prod ) 2>&1 | tail -8

# ──────────────────────────────────────────────────────────────────────────
# 13. Smoke test.
# ──────────────────────────────────────────────────────────────────────────
log "Smoke testing https://$APEX/ …"
sleep 5
curl -sS -o /dev/null -w "  /             HTTP %{http_code}\n" "https://$APEX/"
curl -sS -o /tmp/p_kpis.txt -w "  /stats/kpis   HTTP %{http_code}\n" --max-time 30 "https://$APEX/stats/kpis"
head -c 200 /tmp/p_kpis.txt; echo

curl -sS -X POST "https://$APEX/v1/chat" \
  -H 'Content-Type: application/json' \
  -H "X-Tenant-ID: $(v TELEGRAM_DEFAULT_TENANT_ID)" \
  --max-time 60 \
  -d "{\"tenant_id\":\"$(v TELEGRAM_DEFAULT_TENANT_ID)\",\"message\":\"prod smoke test\"}" \
  -o /tmp/p_chat.txt -w "  /v1/chat      HTTP %{http_code} (took %{time_total}s)\n"
head -c 400 /tmp/p_chat.txt; echo

ok "Prod cutover complete."
