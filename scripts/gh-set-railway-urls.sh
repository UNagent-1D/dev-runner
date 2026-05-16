#!/usr/bin/env bash
# scripts/gh-set-railway-urls.sh — push the public Railway service URLs
# (the ones the Cloudflare Worker reverse-proxies to) as GitHub repository
# variables so the deploy workflows' smoke-test jobs can probe them.
#
# Idempotent: re-run after generating a new domain on Railway.
#
# Usage:
#   scripts/gh-set-railway-urls.sh           # dev only (default)
#   scripts/gh-set-railway-urls.sh dev prod  # both environments

set -euo pipefail

REPO="UNagent-1D/dev-runner"

# Maps the GH variable suffix → the actual Railway service name. The
# variable is RAILWAY_<ENV>_<KEY>_URL, e.g. RAILWAY_DEV_ORCH_URL.
SUFFIXES=(ORCH       TENANT  CHAT              COMPLIANCE)
SERVICES=(chat-orch  tenant  conversation-chat compliance)

log()  { printf "\033[1;36m▶\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m✘\033[0m %s\n" "$*" >&2; exit 1; }

command -v railway >/dev/null || err "railway CLI not installed"
command -v gh      >/dev/null || err "gh CLI not installed"
command -v jq      >/dev/null || err "jq not installed"
gh auth status >/dev/null 2>&1 || err "Run \`gh auth login\` first."

# Default to dev only; allow `dev prod` or just `prod` as args.
TARGETS=("$@")
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(dev)

# Extract a service's public hostname. We try three sources in order:
#   1. `railway domain --json` (different shapes across CLI versions — walk
#      recursively for any "domain" or "host" field)
#   2. plain `railway domain` (usually prints the URL as text)
#   3. wrangler.toml's BACKEND_*_<env> variable, since the user already
#      filled those in when deploying the Worker
get_service_url() {
  local svc="$1" env="$2" suffix="$3"
  local out url=""

  # Source 1: JSON. Walk for any object with a domain-like field.
  out=$(railway domain --service "$svc" --environment "$env" --json 2>/dev/null || true)
  url=$(printf '%s' "$out" | jq -r '
    first(.. | objects |
      (.domain? // .host? // .serviceDomain? // empty)
      | select(type == "string" and length > 0)
    ) // empty
  ' 2>/dev/null || true)
  [ -n "$url" ] && { printf '%s' "$url"; return; }

  # Source 2: plain text. The CLI usually prints "https://X.up.railway.app".
  out=$(railway domain --service "$svc" --environment "$env" 2>/dev/null || true)
  url=$(printf '%s' "$out" \
        | grep -oE 'https?://[A-Za-z0-9.-]+\.up\.railway\.app' | head -1 \
        | sed 's|https\?://||')
  [ -n "$url" ] && { printf '%s' "$url"; return; }

  # Source 3: wrangler.toml fallback. Pull from the matching BACKEND_*_<env>.
  local env_upper
  env_upper=$(printf '%s' "$env" | tr '[:lower:]' '[:upper:]')
  local key
  case "$suffix" in
    ORCH)       key="BACKEND_ORCH" ;;
    TENANT)     key="BACKEND_TENANT" ;;
    CHAT)       key="BACKEND_CHAT" ;;
    COMPLIANCE) key="BACKEND_COMPLIANCE" ;;
  esac
  if [ -f cloudflare-worker/wrangler.toml ]; then
    url=$(awk -v env_block="\\[env.${env}.vars\\]" '
            $0 ~ env_block { in_block=1; next }
            /^\[/ { in_block=0 }
            in_block
          ' cloudflare-worker/wrangler.toml \
          | grep -E "^${key}[[:space:]]*=" | head -1 \
          | sed -E 's/^[^=]+=[[:space:]]*"?([^"]*)"?.*/\1/' \
          | sed 's|https\?://||')
    [ -n "$url" ] && { printf '%s' "$url"; return; }
  fi

  # Nothing worked.
  return 1
}

set_urls_for_env() {
  local env="$1"
  local env_upper
  env_upper=$(printf '%s' "$env" | tr '[:lower:]' '[:upper:]')
  log "── Environment: $env ──"

  for i in "${!SUFFIXES[@]}"; do
    local suffix="${SUFFIXES[$i]}"
    local svc="${SERVICES[$i]}"
    local var_name="RAILWAY_${env_upper}_${suffix}_URL"
    local url

    url=$(get_service_url "$svc" "$env" "$suffix" || true)
    if [ -z "$url" ]; then
      warn "  [$svc] no domain found (Railway JSON, text, or wrangler.toml) — skipping $var_name"
      continue
    fi

    gh variable set "$var_name" --body "https://$url" --repo "$REPO" >/dev/null
    printf "  \033[1;32m✓\033[0m %s = https://%s\n" "$var_name" "$url"
  done
}

for env in "${TARGETS[@]}"; do
  set_urls_for_env "$env"
done

ok "Done. Verify what's set:"
echo "  gh variable list --repo $REPO"
