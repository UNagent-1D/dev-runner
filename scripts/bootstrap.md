# Bootstrap — first-time setup

This document covers the three things `scripts/bootstrap.sh` cannot do for you (because they involve another tool's UI or a secret you control). Everything else — creating the Railway project, services, data stores, environments, variables, public domains, the Cloudflare Worker, and the custom-domain bindings — is automatic.

## 1. Fill in the `.env` files

```sh
cp .env.dev.example  .env.dev
cp .env.prod.example .env.prod
```

Then edit both files. The placeholders you must replace:

- `OPENROUTER_API_KEY` — https://openrouter.ai/keys
- `SENDGRID_API_KEY` — https://app.sendgrid.com/settings/api_keys (sandbox-mode key is fine for `.env.dev`)
- `JWT_SECRET` — `openssl rand -hex 48`
- `TENANT_DB_PASSWORD`, `HOSPITAL_DB_PASSWORD`, `CONVERSATION_MONGO_PASSWORD`, `EMAIL_MONGO_PASSWORD` — each `openssl rand -hex 24`. **Never** reuse the same password across dev and prod.
- `CORS_ALLOW_ORIGIN`, `EMAIL_FROM_DEFAULT` — replace `YOUR_APEX` with the domain you own (e.g. `unagent.example.com`).

`.env.dev` and `.env.prod` are gitignored. **The bootstrap reads them — they are the single source of truth for your Railway configuration.** Re-running `scripts/bootstrap.sh --sync-env` after editing either file pushes the new values to Railway shared variables without recreating any service.

## 2. GitHub secrets

After `scripts/bootstrap.sh` finishes, it prints a list of secrets to set. Paste them at GitHub → repo → Settings → Secrets and variables → Actions:

| Secret name | How to get it |
|---|---|
| `RAILWAY_TOKEN_DEV` | https://railway.com/account/tokens → Create. Scope: project `unagent`, environment `dev`. |
| `RAILWAY_TOKEN_PROD` | Same URL. Scope: project `unagent`, environment `prod`. |
| `CLOUDFLARE_API_TOKEN` | Cloudflare dashboard → My Profile → API Tokens → Create. Template "Edit Cloudflare Workers". Account scope. |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare dashboard, right sidebar of any zone. |
| `SUBMODULES_TOKEN` | GitHub → Settings → Developer settings → Fine-grained PAT. Scope: read-only on the `UNagent-1D` org. |

## 3. Cloudflare zone

The Cloudflare Worker binds to two domains:

- `<apex>` → prod Worker (e.g. `unagent.example.com`)
- `dev.<apex>` → dev Worker (e.g. `dev.unagent.example.com`)

Before running the bootstrap, make sure:

1. The apex zone (`<apex>`) is already added to your Cloudflare account.
2. DNS is pointing at Cloudflare nameservers (the zone shows "Active" in the dashboard).

Wrangler creates the Custom Domain bindings + provisions TLS automatically on first deploy. You do **not** need to add CNAME records by hand.

## What happens during bootstrap

`scripts/bootstrap.sh` runs end-to-end:

1. **Railway login** (interactive on first run).
2. **Create / link project** `unagent`.
3. **For each environment (`dev`, `prod`):**
   - Create environment.
   - Upload `.env.<env>` keys as Railway shared variables.
   - Create the 6 data-store services (`redis`, `email-mongo`, `conversation-mongo`, `hospital-postgres`, `tenant-postgres`, `rabbitmq`) with volumes.
   - Create the 8 application services with `Dockerfile Path` and per-service `${{ shared.* }}` variable references.
   - Generate public Railway URLs for the 4 Worker-facing services.
4. **Render `cloudflare-worker/wrangler.toml`** from the template (substituting the Railway URLs + your apex domain).
5. **Build the Vite SPA** and `wrangler deploy --env dev|prod` — Cloudflare creates the Custom Domain bindings.
6. **Print GitHub secrets** to paste into Actions settings.

## Manual fallbacks

A handful of Railway settings still require a dashboard click — the CLI exposes them inconsistently across versions. The script warns when this is needed; the actual operations are tiny:

- Setting the image for the public-image data stores (`redis:7-alpine`, `mongo:7`) — go to the service → Settings → Source → Image.
- Setting the Dockerfile path for the custom-image data stores (`tenant-postgres`, `hospital-postgres`, `rabbitmq`) and for each application service — service → Settings → Source → Dockerfile Path.
- Attaching the volume — service → Volumes → Mount Path.

If/when the Railway CLI gains coverage for these, the script will update; the rest of the bootstrap is already non-interactive.

## Updating values later

- Changed a value in `.env.dev`? Run `scripts/bootstrap.sh --sync-env` — push only, no service recreation.
- Added a new shared variable that an existing service needs? Add it to `SERVICE_VARS[<svc>]` in `bootstrap.sh` and rerun the script (it's idempotent).
- Added a brand-new service? Append it to `APP_SERVICES` in `bootstrap.sh`, add a Dockerfile to the relevant submodule, rerun the script.
