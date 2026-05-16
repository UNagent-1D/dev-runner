// UNAgent edge gateway — Cloudflare Worker.
//
// Replaces the local nginx single-origin proxy (FrontEnd/nginx.conf:41-87)
// in production. Browser sees one origin (dev.<apex> / <apex>); the Worker
// fans out to Railway backends and serves the Vite SPA bundle.
//
// Path order mirrors the nginx config (longest prefix wins). If you add
// a new backend route, mirror it here AND in nginx.conf so local compose
// stays in sync.

import { proxy, proxySse } from "./proxy";

interface Env {
  ASSETS: Fetcher;
  BACKEND_ORCH: string;
  BACKEND_TENANT: string;
  BACKEND_CHAT: string;
  BACKEND_COMPLIANCE: string;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const p = url.pathname;

    // chat-orch — SSE stream (must not buffer; long-lived connection).
    if (p.startsWith("/v1/chat/stream")) {
      return proxySse(req, env.BACKEND_ORCH);
    }
    // chat-orch — POST /v1/chat, /v1/feedback, everything else under /v1/.
    if (p.startsWith("/v1/")) return proxy(req, env.BACKEND_ORCH);

    // Tenant — login + admin CRUD + per-tenant CRUD.
    if (p.startsWith("/auth/")) return proxy(req, env.BACKEND_TENANT);
    if (p.startsWith("/api/admin/")) return proxy(req, env.BACKEND_TENANT);
    if (p.startsWith("/api/v1/tenants/")) return proxy(req, env.BACKEND_TENANT);

    // conversation-chat — sessions API.
    if (p.startsWith("/api/v1/sessions/")) return proxy(req, env.BACKEND_CHAT);

    // Compliance — KPI cards + timeseries.
    if (p.startsWith("/stats/")) return proxy(req, env.BACKEND_COMPLIANCE);

    // Anything else: SPA static assets, with index.html fallback for
    // client-side routes (configured via not_found_handling in wrangler.toml).
    return env.ASSETS.fetch(req);
  },
} satisfies ExportedHandler<Env>;
