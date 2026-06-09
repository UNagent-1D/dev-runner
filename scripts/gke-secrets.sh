#!/usr/bin/env bash
# Map the umbrella .env.<env> (the same files Railway consumed as shared vars)
# into the platform-secrets Secret the k8s manifests expect, in the right GKE
# namespace. Run BEFORE the first `make -C k8s gke-deploy ENV=<env>`.
#
#   scripts/gke-secrets.sh prod   ->  platform-secrets in ns unagent-prod
#   scripts/gke-secrets.sh dev    ->  platform-secrets in ns unagent-dev
#
# Key points:
#  - DSNs are REBUILT against k8s service DNS from the *_DB_* parts; the
#    DATABASE_URL/MONGO_URI/REDIS_URL/RABBITMQ_URL values in the .env files
#    point at railway.internal hosts and are never passed through.
#  - Keys the .env files don't carry get Railway-parity defaults
#    (INTERNAL_API_KEY=dev-internal-key — rotate after cutover).
#  - Values are never echoed; output is key names only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="${1:?usage: gke-secrets.sh <prod|dev>}"
case "$ENV" in prod|dev) ;; *) echo "env must be prod or dev" >&2; exit 1 ;; esac
NS="unagent-$ENV"
ENVFILE="$ROOT/.env.$ENV"
[ -f "$ENVFILE" ] || { echo "missing $ENVFILE" >&2; exit 1; }

# Load (values may reference other vars; shell sourcing expands them)
set -a
# shellcheck disable=SC1090
. "$ENVFILE"
set +a

req() { # req VAR — fail if unset/empty
  local v="${!1:-}"
  [ -n "$v" ] || { echo "!! $1 is empty in .env.$ENV" >&2; exit 1; }
}
req OPENROUTER_API_KEY; req JWT_SECRET; req SENDGRID_API_KEY
req TENANT_DB_USER; req TENANT_DB_PASSWORD; req TENANT_DB_NAME
req HOSPITAL_DB_USER; req HOSPITAL_DB_PASSWORD; req HOSPITAL_DB_NAME

# The StatefulSets hardcode POSTGRES_USER=tenant|hospital and probe with the
# same users — refuse creds that can't match the server side.
[ "$TENANT_DB_USER" = "tenant" ]     || { echo "!! TENANT_DB_USER must be 'tenant' (tenant-postgres hardcodes it)" >&2; exit 1; }
[ "$HOSPITAL_DB_USER" = "hospital" ] || { echo "!! HOSPITAL_DB_USER must be 'hospital' (hospital-postgres hardcodes it)" >&2; exit 1; }

# Secure channel: both Railway envs run with ENABLED=true — the key must exist.
if [ "${BACKEND_CHANNEL_ENABLED:-false}" = "true" ]; then
  req BACKEND_CHANNEL_KEY
fi

INTERNAL_API_KEY="${INTERNAL_API_KEY:-dev-internal-key}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
SEED_PASSWORD="${SEED_PASSWORD:-demo1234}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
BACKEND_CHANNEL_KEY="${BACKEND_CHANNEL_KEY:-}"

DATABASE_URL_TENANT="postgres://${TENANT_DB_USER}:${TENANT_DB_PASSWORD}@tenant-postgres:5432/${TENANT_DB_NAME}?sslmode=disable"
DATABASE_URL_USER_AUTH="postgresql://${TENANT_DB_USER}:${TENANT_DB_PASSWORD}@tenant-postgres:5432/user_auth?sslmode=disable"
DATABASE_URL_HOSPITAL="postgresql://${HOSPITAL_DB_USER}:${HOSPITAL_DB_PASSWORD}@hospital-postgres:5432/${HOSPITAL_DB_NAME}"

for url in "$DATABASE_URL_TENANT" "$DATABASE_URL_USER_AUTH" "$DATABASE_URL_HOSPITAL"; do
  case "$url" in *railway*|*rlwy.net*) echo "!! derived DSN still points at Railway" >&2; exit 1 ;; esac
done

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic platform-secrets -n "$NS" \
  --from-literal=OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
  --from-literal=JWT_SECRET="$JWT_SECRET" \
  --from-literal=INTERNAL_API_KEY="$INTERNAL_API_KEY" \
  --from-literal=BACKEND_CHANNEL_KEY="$BACKEND_CHANNEL_KEY" \
  --from-literal=SENDGRID_API_KEY="$SENDGRID_API_KEY" \
  --from-literal=TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
  --from-literal=POSTGRES_PASSWORD_TENANT="$TENANT_DB_PASSWORD" \
  --from-literal=POSTGRES_PASSWORD_HOSPITAL="$HOSPITAL_DB_PASSWORD" \
  --from-literal=GRAFANA_ADMIN_PASSWORD="$GRAFANA_ADMIN_PASSWORD" \
  --from-literal=SEED_PASSWORD="$SEED_PASSWORD" \
  --from-literal=DATABASE_URL_TENANT="$DATABASE_URL_TENANT" \
  --from-literal=DATABASE_URL_USER_AUTH="$DATABASE_URL_USER_AUTH" \
  --from-literal=DATABASE_URL_HOSPITAL="$DATABASE_URL_HOSPITAL" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">> platform-secrets applied to $NS (keys: OPENROUTER_API_KEY JWT_SECRET INTERNAL_API_KEY BACKEND_CHANNEL_KEY SENDGRID_API_KEY TELEGRAM_BOT_TOKEN POSTGRES_PASSWORD_TENANT POSTGRES_PASSWORD_HOSPITAL GRAFANA_ADMIN_PASSWORD SEED_PASSWORD DATABASE_URL_TENANT DATABASE_URL_USER_AUTH DATABASE_URL_HOSPITAL)"
