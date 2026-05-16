# UNAgent gateway — Cloudflare Worker

This Worker is the production single-origin gateway for UNAgent. It:

1. Serves the Vite SPA bundle from `../FrontEnd/dist` (via the `[assets]` binding).
2. Reverse-proxies `/v1/*`, `/auth/*`, `/api/admin/*`, `/api/v1/tenants/*`, `/api/v1/sessions/*`, `/stats/*` to the right Railway backend.
3. Pass-throughs SSE for `/v1/chat/stream` token-by-token.

Routing is in `src/index.ts`; backend selection mirrors `FrontEnd/nginx.conf` in the umbrella so local compose and prod stay in sync.

## First-time setup

You don't run this directly — `scripts/bootstrap.sh` at the umbrella root does it. Bootstrap:

1. Substitutes `wrangler.toml.template` → `wrangler.toml` (your apex + the Railway backend hostnames it captured).
2. Runs `wrangler deploy --env dev` and `wrangler deploy --env prod`. Cloudflare creates the Custom Domain + TLS automatically.

## Local development

```sh
cp .dev.vars.example .dev.vars   # edit if you want to point at different backends
cd ../FrontEnd && npm run build  # produces ../FrontEnd/dist
cd ../cloudflare-worker
npm ci
npm run dev                      # http://localhost:8787
```

`npm run dev` uses the dev backends from `.dev.vars`. If you'd rather hit `docker compose` locally, just run that stack — the Worker isn't required for the inner dev loop; the FrontEnd nginx container is the local equivalent.

## Deploy

CI does this automatically on push to `dev` / `main`. Manual:

```sh
npm run deploy:dev
npm run deploy:prod
```

## Typecheck

```sh
npm run typecheck                # wrangler types + tsc --noEmit
```

Run after editing `wrangler.toml` env bindings so the generated `Env` interface stays in sync.
