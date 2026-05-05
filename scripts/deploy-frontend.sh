#!/usr/bin/env bash
# Deploy the FrontEnd SPA to Cloudflare Pages.
#
# What it does:
#   1. Installs wrangler (Cloudflare CLI) under the FrontEnd workspace if missing.
#   2. Logs in to Cloudflare on first run (browser flow).
#   3. Builds the Vite bundle with VITE_* baked at build time, pointing at the
#      tunnelled backend hostnames.
#   4. Creates the Pages project on first run, then `wrangler pages deploy`s
#      the dist/ folder.
#   5. Prints next steps for adding the custom domain (`app.unagent.site`).
#
# Re-run after any FrontEnd change to push a new build.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FE="$ROOT/FrontEnd"
PROJECT="unagent-frontend"
PROD_BRANCH="main"

# Public hostnames the bundle will call. Change here if the domain ever moves.
export VITE_TENANT_API_URL="https://api.unagent.site"
export VITE_ORCH_API_URL="https://orch.unagent.site"
export VITE_CHAT_API_URL="https://chat.unagent.site/api/v1"
export VITE_METRICAS_API_URL="https://metrics.unagent.site"

cd "$FE"

# ---------------------------------------------------------------------------
# 0. sanity checks
# ---------------------------------------------------------------------------
command -v node    >/dev/null || { echo "✗ node not on PATH"; exit 1; }
command -v pnpm    >/dev/null || npm i -g pnpm   # FrontEnd uses pnpm 10
command -v npx     >/dev/null || { echo "✗ npx missing (install Node 18+)"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Install / refresh deps
# ---------------------------------------------------------------------------
if [ ! -d node_modules ]; then
  echo "▶ pnpm install (first run)"
  pnpm install --frozen-lockfile
fi

# wrangler — prefer the globally installed binary; fall back to npx --yes
# (auto-installs the latest into the npx cache, no global pollution).
if command -v wrangler >/dev/null 2>&1; then
  WRANGLER=(wrangler)
else
  echo "▶ wrangler not found globally — using 'npx --yes wrangler@latest'"
  WRANGLER=(npx --yes wrangler@latest)
fi
wrangler() { command "${WRANGLER[@]}" "$@"; }

# ---------------------------------------------------------------------------
# 2. Log in (browser flow, only on first run)
# ---------------------------------------------------------------------------
if ! wrangler whoami >/dev/null 2>&1; then
  echo
  echo "▶ wrangler login (opens your browser; pick the unagent.site account → Authorize)"
  wrangler login
fi
wrangler whoami

# ---------------------------------------------------------------------------
# 3. Build the Vite bundle with the production VITE_* values
# ---------------------------------------------------------------------------
echo
echo "▶ pnpm build  (VITE_* env baked in)"
pnpm build

[ -d dist ] || { echo "✗ build did not produce dist/"; exit 1; }

# ---------------------------------------------------------------------------
# 4. Create the Pages project on first deploy (idempotent: ignore "exists")
# ---------------------------------------------------------------------------
wrangler pages project create "$PROJECT" \
  --production-branch="$PROD_BRANCH" \
  2>&1 | sed 's/^/  /' || true

# ---------------------------------------------------------------------------
# 5. Deploy
# ---------------------------------------------------------------------------
echo
echo "▶ wrangler pages deploy dist/  →  $PROJECT (production)"
# Omitting --branch so wrangler targets the project's production branch
# (Pages otherwise treats the deploy as a Preview environment and the
# unagent-frontend.pages.dev alias serves "Deployment Not Found").
wrangler pages deploy dist \
  --project-name "$PROJECT" \
  --commit-dirty=true

# ---------------------------------------------------------------------------
# 6. Next steps
# ---------------------------------------------------------------------------
cat <<EOF

✓ Deploy complete.

Pages dashboard:
  https://dash.cloudflare.com/?to=/:account/pages/view/$PROJECT

Default URL:
  https://$PROJECT.pages.dev

Add the custom domain (one-time, via UI):
  1. Open the Pages project → "Custom domains" tab.
  2. "Set up a custom domain" → enter:  app.unagent.site
  3. Cloudflare auto-creates the CNAME and provisions TLS in ~1 min.

Re-run this script after any FrontEnd commit to push a new build.

EOF
