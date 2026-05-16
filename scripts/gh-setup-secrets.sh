#!/usr/bin/env bash
# scripts/gh-setup-secrets.sh — provision GitHub environments, secrets, and
# variables via the gh CLI. Mirrors the table in scripts/bootstrap.md §2.
#
# Idempotent. Re-run after rotating any token; gh secret set overwrites.
#
# Requires:
#   - gh CLI authenticated (`gh auth login` if not already)
#   - You have admin rights on UNagent-1D/dev-runner

set -euo pipefail

REPO="UNagent-1D/dev-runner"

log()  { printf "\033[1;36m▶\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m✘\033[0m %s\n" "$*" >&2; exit 1; }

command -v gh >/dev/null || err "gh CLI not installed (https://cli.github.com)"
gh auth status >/dev/null 2>&1 || err "Run \`gh auth login\` first."

log "Repository: $REPO"

# ──────────────────────────────────────────────────────────────────────────
# 1. Create dev + prod environments (idempotent — PUT upserts).
# ──────────────────────────────────────────────────────────────────────────
for env in dev prod; do
  log "Ensuring environment '$env' exists…"
  gh api -X PUT "repos/$REPO/environments/$env" --silent
done

# Restrict prod environment to deploy only from `main`. This is the same
# guard the pr-gate.yml workflow enforces, doubled at the GitHub-environment
# level so an out-of-band workflow_dispatch can't bypass it either.
log "Restricting prod environment to branch 'main'…"
gh api -X PUT "repos/$REPO/environments/prod" \
  --silent \
  -F deployment_branch_policy[protected_branches]=false \
  -F deployment_branch_policy[custom_branch_policies]=true
# Add the 'main' branch policy. Errors if it already exists; we swallow.
gh api -X POST "repos/$REPO/environments/prod/deployment-branch-policies" \
  --silent -f name=main 2>/dev/null || true
ok "Environments configured."

# ──────────────────────────────────────────────────────────────────────────
# 2. Prompt for each secret. Silent reads (-s), no shell-history leak.
# ──────────────────────────────────────────────────────────────────────────
prompt_secret() {
  local var_name="$1" prompt="$2"
  local val=""
  while [ -z "$val" ]; do
    printf "  %s: " "$prompt" >&2
    read -rs val
    echo >&2
    [ -z "$val" ] && warn "  (empty — try again)"
  done
  printf '%s' "$val"
}

echo ""
log "Paste each token (input is hidden). Press Enter after each."

RAILWAY_TOKEN_DEV=$(prompt_secret RAILWAY_TOKEN_DEV  "RAILWAY_TOKEN_DEV   (railway.com/account/tokens, scope: project=unagent env=dev)")
RAILWAY_TOKEN_PROD=$(prompt_secret RAILWAY_TOKEN_PROD "RAILWAY_TOKEN_PROD  (same URL, scope: project=unagent env=prod)")
CLOUDFLARE_API_TOKEN=$(prompt_secret CLOUDFLARE_API_TOKEN "CLOUDFLARE_API_TOKEN (the 'Edit Cloudflare Workers' token you made earlier)")
SUBMODULES_TOKEN=$(prompt_secret SUBMODULES_TOKEN     "SUBMODULES_TOKEN     (GitHub fine-grained PAT, repo:read on UNagent-1D)")
echo ""

# Account ID is non-secret (it appears in wrangler logs) but storing as a
# repository secret is still cleanest for `secrets.X` workflow references.
CLOUDFLARE_ACCOUNT_ID="9e6e913d37cddd09d2ee104ddbd4a04e"

# ──────────────────────────────────────────────────────────────────────────
# 3. Repository secrets (visible to every workflow in this repo).
# ──────────────────────────────────────────────────────────────────────────
log "Setting repository secrets…"
printf '%s' "$CLOUDFLARE_API_TOKEN"  | gh secret set CLOUDFLARE_API_TOKEN  --repo "$REPO"
printf '%s' "$CLOUDFLARE_ACCOUNT_ID" | gh secret set CLOUDFLARE_ACCOUNT_ID --repo "$REPO"
printf '%s' "$SUBMODULES_TOKEN"      | gh secret set SUBMODULES_TOKEN      --repo "$REPO"
ok "Repository secrets set."

# ──────────────────────────────────────────────────────────────────────────
# 4. Environment secrets (only the matching env can read).
# ──────────────────────────────────────────────────────────────────────────
log "Setting environment secrets…"
printf '%s' "$RAILWAY_TOKEN_DEV"  | gh secret set RAILWAY_TOKEN_DEV  --env dev  --repo "$REPO"
printf '%s' "$RAILWAY_TOKEN_PROD" | gh secret set RAILWAY_TOKEN_PROD --env prod --repo "$REPO"
ok "Environment secrets set."

# ──────────────────────────────────────────────────────────────────────────
# 5. Repository variables — the apex domains the smoke tests probe.
#    Railway service URLs added separately once they exist.
# ──────────────────────────────────────────────────────────────────────────
log "Setting repository variables…"
gh variable set DEV_APEX  --body "dev.unagent.site" --repo "$REPO"
gh variable set PROD_APEX --body "unagent.site"     --repo "$REPO"
ok "Repository variables set."

echo ""
ok "All done. Next steps:"
cat <<EOF

  1. (optional) On Settings → Environments → prod, enable Required reviewers
     for a manual approval gate. gh CLI can't set this without org owner
     scope, so it's a one-click in the UI.

  2. Once Railway public URLs exist for chat-orch, tenant, conversation-chat,
     and compliance (dev env), set the smoke-test URLs:

     for svc in ORCH TENANT CHAT COMPLIANCE; do
       lc=\$(echo \$svc | tr '[:upper:]' '[:lower:]')
       url=\$(railway domain --service \$lc --environment dev --json | jq -r '.[0].domain')
       gh variable set "RAILWAY_DEV_\${svc}_URL" --body "https://\$url" --repo "$REPO"
     done

  3. Push to dev and watch GitHub Actions:

     git checkout -b dev && git push -u origin dev

EOF
