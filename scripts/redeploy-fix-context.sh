#!/usr/bin/env bash
# scripts/redeploy-fix-context.sh — redeploy app services from INSIDE each
# submodule so Railway uses the submodule as the build context. The COPY
# commands inside each Dockerfile expect that.
#
# Data stores stay deployed from the umbrella root (their custom Dockerfiles
# COPY files from multiple submodule paths, so they need the umbrella as
# context).
#
# Re-runnable safely.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
UMBRELLA="$(pwd)"

log() { printf "\033[1;36m▶\033[0m %s\n" "$*"; }
ok()  { printf "\033[1;32m✓\033[0m %s\n" "$*"; }

railway environment dev >/dev/null
ok "Linked to dev environment."

# Reset RAILWAY_DOCKERFILE_PATH per service so it makes sense for the new
# upload root. Data stores: full path from umbrella. App services: just
# "Dockerfile" (relative to the submodule they'll be uploaded from).
log "Resetting RAILWAY_DOCKERFILE_PATH per service…"
railway variables --service redis              --set "RAILWAY_DOCKERFILE_PATH=scripts/data-stores/redis.Dockerfile" >/dev/null
railway variables --service email-mongo        --set "RAILWAY_DOCKERFILE_PATH=scripts/data-stores/email-mongo.Dockerfile" >/dev/null
railway variables --service conversation-mongo --set "RAILWAY_DOCKERFILE_PATH=scripts/data-stores/conversation-mongo.Dockerfile" >/dev/null
railway variables --service hospital-postgres  --set "RAILWAY_DOCKERFILE_PATH=scripts/data-stores/hospital-postgres.Dockerfile" >/dev/null
railway variables --service tenant-postgres    --set "RAILWAY_DOCKERFILE_PATH=scripts/data-stores/tenant-postgres.Dockerfile" >/dev/null

# rabbitmq + 7 app services: Dockerfile at submodule root.
for svc in rabbitmq tenant hospital-mock agent-runtime conversation-chat chat-orch compliance email-send; do
  railway variables --service "$svc" --set "RAILWAY_DOCKERFILE_PATH=Dockerfile" >/dev/null
done
ok "Dockerfile paths reset."

# ──────────────────────────────────────────────────────────────────────────
# Data stores — deploy from umbrella (their COPYs span multiple submodules).
# hospital-postgres + tenant-postgres + the 3 thin wrappers were already
# building OK; redeploy is idempotent and ensures they pick up any var
# changes from fix-dev-deploy.sh (POSTGRES_PASSWORD etc.).
# ──────────────────────────────────────────────────────────────────────────
log "── Data stores (from umbrella root) ──"
for svc in redis email-mongo conversation-mongo hospital-postgres tenant-postgres; do
  log "[$svc] railway up --detach"
  ( cd "$UMBRELLA" && railway up --service "$svc" --detach )
done

# ──────────────────────────────────────────────────────────────────────────
# rabbitmq + app services — deploy from INSIDE the submodule directory.
# This makes the submodule the build context, so COPYs in each Dockerfile
# work the way they were written for local docker-compose.
# ──────────────────────────────────────────────────────────────────────────
declare -A SUBMODULE_OF=(
  [rabbitmq]="UN_message_broker_mb"
  [tenant]="Tenant"
  [hospital-mock]="Hospital-MP"
  [agent-runtime]="agent-runtime"
  [conversation-chat]="conversation-chat"
  [chat-orch]="chat-orch"
  [compliance]="Compliance"
  [email-send]="UN_email_send_ms"
)

log "── App services + rabbitmq (from each submodule dir) ──"
for svc in rabbitmq tenant hospital-mock agent-runtime conversation-chat chat-orch compliance email-send; do
  dir="${SUBMODULE_OF[$svc]}"
  if [ ! -d "$UMBRELLA/$dir" ]; then
    printf "\033[1;31m✘\033[0m  [%s] submodule dir '%s' missing — skipping\n" "$svc" "$dir" >&2
    continue
  fi
  log "[$svc] (cd $dir) railway up --detach"
  ( cd "$UMBRELLA/$dir" && railway up --service "$svc" --detach )
done

ok "All redeploys kicked off. Tail with: railway logs --service <name>"
