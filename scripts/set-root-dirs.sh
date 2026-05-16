#!/usr/bin/env bash
# scripts/set-root-dirs.sh — set Service → Root Directory per service via
# Railway's GraphQL API. Fixes the build-context issue where COPY commands
# in submodule Dockerfiles can't find their files.
#
# Requires:
#   - RAILWAY_API_TOKEN env var (account token from
#     https://railway.com/account/tokens)
#   - jq, curl
#
# Idempotent. Run once; rerun if you add/remove services.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

log() { printf "\033[1;36m▶\033[0m %s\n" "$*"; }
ok()  { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m✘\033[0m %s\n" "$*" >&2; exit 1; }

: "${RAILWAY_API_TOKEN:?Set RAILWAY_API_TOKEN — create one at https://railway.com/account/tokens}"
command -v jq >/dev/null   || err "install jq"
command -v curl >/dev/null || err "install curl"

PROJECT_ID="3d5be088-15a5-4763-8bf1-6332dfd44fd9"
ENV_ID="71057f1f-ca5c-40e8-9ad2-abbdad2237ac"
ENDPOINT="${RAILWAY_GRAPHQL_ENDPOINT:-https://backboard.railway.app/graphql/v2}"

gql() {
  local query="$1"
  local vars="${2:-{\}}"
  curl -sS -X POST "$ENDPOINT" \
    -H "Authorization: Bearer $RAILWAY_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg q "$query" --argjson v "$vars" '{query:$q, variables:$v}')"
}

# ──────────────────────────────────────────────────────────────────────────
# 1. List services in the project so we can map names → IDs.
# ──────────────────────────────────────────────────────────────────────────
log "Fetching service list…"
LIST_Q='query($id: String!){ project(id:$id){ services{ edges{ node{ id name } } } } }'
LIST_RES=$(gql "$LIST_Q" "$(jq -nc --arg id "$PROJECT_ID" '{id:$id}')")
echo "$LIST_RES" | jq -e '.data.project.services' >/dev/null || {
  echo "GraphQL response:"; echo "$LIST_RES" | jq .
  err "Couldn't list services. Token may lack project access — try regenerating, or verify PROJECT_ID."
}

declare -A SVC_IDS
while IFS=$'\t' read -r name id; do
  SVC_IDS["$name"]="$id"
done < <(echo "$LIST_RES" | jq -r '.data.project.services.edges[] | .node | [.name, .id] | @tsv')

log "Found ${#SVC_IDS[@]} services:"
for k in "${!SVC_IDS[@]}"; do printf "    %s → %s\n" "$k" "${SVC_IDS[$k]}"; done

# ──────────────────────────────────────────────────────────────────────────
# 2. Set rootDirectory per service. Data stores stay at umbrella root.
# ──────────────────────────────────────────────────────────────────────────
declare -A ROOTS=(
  [tenant]="Tenant"
  [hospital-mock]="Hospital-MP"
  [agent-runtime]="agent-runtime"
  [conversation-chat]="conversation-chat"
  [chat-orch]="chat-orch"
  [compliance]="Compliance"
  [email-send]="UN_email_send_ms"
  [rabbitmq]="UN_message_broker_mb"
)

# Try the documented mutation. If Railway has renamed the field, the
# response will show an error and we print it for debugging.
UPDATE_Q='mutation($id: String!, $env: String!, $input: ServiceInstanceUpdateInput!){
  serviceInstanceUpdate(serviceId:$id, environmentId:$env, input:$input)
}'

for name in "${!ROOTS[@]}"; do
  root="${ROOTS[$name]}"
  svc_id="${SVC_IDS[$name]:-}"
  if [ -z "$svc_id" ]; then
    printf "  \033[1;33m!\033[0m service '%s' not found in project — skipping\n" "$name" >&2
    continue
  fi
  vars=$(jq -nc \
    --arg id "$svc_id" \
    --arg env "$ENV_ID" \
    --arg root "$root" \
    '{id:$id, env:$env, input:{rootDirectory:$root, dockerfilePath:"Dockerfile"}}')
  res=$(gql "$UPDATE_Q" "$vars")
  if echo "$res" | jq -e '.errors' >/dev/null 2>&1; then
    printf "  \033[1;31m✘\033[0m %s — error:\n" "$name"
    echo "$res" | jq .errors
  else
    printf "  \033[1;32m✓\033[0m %s → %s\n" "$name" "$root"
  fi
done

ok "Done. Now redeploy from the umbrella root:"
cat <<'EOF'

    cd /home/juloaizar/Documents/university/archsoft/dev-runner
    for svc in tenant hospital-mock agent-runtime conversation-chat chat-orch compliance email-send rabbitmq; do
      railway up --service "$svc" --detach
    done

EOF
