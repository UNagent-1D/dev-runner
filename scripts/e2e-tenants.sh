#!/usr/bin/env bash
# End-to-end smoke test for the Tenant service admin CRUD used by the
# FrontEnd's Organization Management page.
#
# Requires: the umbrella stack running locally (`docker compose up -d`),
# plus an existing app_admin user. Supply credentials with env vars:
#   APP_ADMIN_EMAIL=admin@example.com APP_ADMIN_PASSWORD=... ./scripts/e2e-tenants.sh
#
# Exits non-zero on any failure, with the offending HTTP response echoed.

set -euo pipefail

TENANT_URL=${TENANT_URL:-http://localhost:8080}
APP_ADMIN_EMAIL=${APP_ADMIN_EMAIL:?set APP_ADMIN_EMAIL to an existing app_admin user}
APP_ADMIN_PASSWORD=${APP_ADMIN_PASSWORD:?set APP_ADMIN_PASSWORD}

RUN_ID=$(date +%s)
NEW_TENANT_NAME="e2e-tenant-${RUN_ID}"
NEW_TENANT_DOMAIN="e2e-${RUN_ID}.test"
NEW_USER_EMAIL="e2e-admin-${RUN_ID}@example.com"
NEW_USER_PASSWORD="ChangeMe!${RUN_ID}"

say() { printf "\033[1;36m▸ %s\033[0m\n" "$*"; }
fail() { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"; }
need curl
need jq

say "health check"
curl -fsS "${TENANT_URL}/health" | jq -e '.status == "ok"' >/dev/null \
  || fail "Tenant /health did not return ok"

say "login as app_admin"
LOGIN_RESP=$(curl -fsS -X POST "${TENANT_URL}/auth/login" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg e "$APP_ADMIN_EMAIL" --arg p "$APP_ADMIN_PASSWORD" '{email:$e,password:$p}')")
TOKEN=$(echo "$LOGIN_RESP" | jq -r '.token')
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || fail "login failed: $LOGIN_RESP"

say "list tenants before create"
BEFORE=$(curl -fsS "${TENANT_URL}/api/admin/tenants" -H "Authorization: Bearer $TOKEN")
BEFORE_COUNT=$(echo "$BEFORE" | jq 'length')

say "create tenant ($NEW_TENANT_NAME)"
CREATE_RESP=$(curl -fsS -X POST "${TENANT_URL}/api/admin/tenants" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg n "$NEW_TENANT_NAME" --arg d "$NEW_TENANT_DOMAIN" '{name:$n,domain:$d}')")
TENANT_ID=$(echo "$CREATE_RESP" | jq -r '.id')
[ -n "$TENANT_ID" ] && [ "$TENANT_ID" != "null" ] || fail "create tenant failed: $CREATE_RESP"
echo "  id=$TENANT_ID"

say "list tenants after create (expect +1)"
AFTER=$(curl -fsS "${TENANT_URL}/api/admin/tenants" -H "Authorization: Bearer $TOKEN")
AFTER_COUNT=$(echo "$AFTER" | jq 'length')
[ "$AFTER_COUNT" = "$((BEFORE_COUNT + 1))" ] \
  || fail "expected $((BEFORE_COUNT + 1)) tenants, got $AFTER_COUNT"
echo "$AFTER" | jq -e --arg id "$TENANT_ID" 'map(.id) | index($id) != null' >/dev/null \
  || fail "new tenant id $TENANT_ID missing from listing"

say "create tenant_admin user on new tenant"
USER_RESP=$(curl -fsS -X POST "${TENANT_URL}/api/admin/users" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "$(jq -nc \
        --arg email "$NEW_USER_EMAIL" \
        --arg pw "$NEW_USER_PASSWORD" \
        --arg tid "$TENANT_ID" \
        '{email:$email, password:$pw, first_name:"E2E", last_name:"Admin", role:"tenant_admin", tenant_id:$tid}')")
USER_ID=$(echo "$USER_RESP" | jq -r '.user_id')
[ -n "$USER_ID" ] && [ "$USER_ID" != "null" ] || fail "create user failed: $USER_RESP"
echo "  id=$USER_ID"

say "login as new tenant_admin"
NEW_LOGIN=$(curl -fsS -X POST "${TENANT_URL}/auth/login" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg e "$NEW_USER_EMAIL" --arg p "$NEW_USER_PASSWORD" '{email:$e,password:$p}')")
NEW_TOKEN=$(echo "$NEW_LOGIN" | jq -r '.token')
[ -n "$NEW_TOKEN" ] && [ "$NEW_TOKEN" != "null" ] || fail "new-user login failed: $NEW_LOGIN"

say "decode JWT and verify tenant_id + role"
PAYLOAD=$(echo "$NEW_TOKEN" | awk -F. '{print $2}')
while [ $(( ${#PAYLOAD} % 4 )) -ne 0 ]; do PAYLOAD="${PAYLOAD}="; done
DECODED=$(echo "$PAYLOAD" | tr '_-' '/+' | base64 -d 2>/dev/null)
echo "$DECODED" | jq -e --arg tid "$TENANT_ID" '.tenant_id == $tid and .role == "tenant_admin"' >/dev/null \
  || fail "JWT claims mismatch: $DECODED"

say "negative: duplicate tenant domain should 409"
HTTP=$(curl -s -o /tmp/dup.json -w "%{http_code}" -X POST "${TENANT_URL}/api/admin/tenants" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg n "dup-${RUN_ID}" --arg d "$NEW_TENANT_DOMAIN" '{name:$n,domain:$d}')")
[ "$HTTP" = "409" ] || fail "expected 409 on duplicate domain, got $HTTP: $(cat /tmp/dup.json)"

say "negative: create user with invalid role should 400"
HTTP=$(curl -s -o /tmp/bad.json -w "%{http_code}" -X POST "${TENANT_URL}/api/admin/users" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"email":"x@x.com","password":"abcdef","first_name":"a","last_name":"b","role":"bogus"}')
[ "$HTTP" = "400" ] || fail "expected 400 on bogus role, got $HTTP: $(cat /tmp/bad.json)"

printf "\n\033[1;32m✓ e2e passed (tenant=%s, user=%s)\033[0m\n" "$TENANT_ID" "$USER_ID"
