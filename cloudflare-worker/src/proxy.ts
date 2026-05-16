// Streaming-aware reverse-proxy helpers.
//
// Cloudflare Workers natively pass through ReadableStream response bodies,
// so SSE works without any chunk re-encoding — we just hand back the upstream
// body. The non-streaming helper is the same call shape; we keep them split
// for readability (and so future Cache-Control / timing logic only touches
// one path).

const HOP_BY_HOP = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
  "content-length",
]);

function buildUpstreamUrl(req: Request, backend: string): string {
  const incoming = new URL(req.url);
  const target = new URL(backend);
  target.pathname = incoming.pathname;
  target.search = incoming.search;
  return target.toString();
}

function buildUpstreamHeaders(req: Request): Headers {
  const headers = new Headers(req.headers);
  // Cloudflare sets cf-* headers; strip the obvious noise. The remaining
  // Authorization, Cookie, X-Tenant-ID, etc. flow through unchanged.
  headers.delete("host");
  return headers;
}

export async function proxy(req: Request, backend: string): Promise<Response> {
  const upstream = await fetch(buildUpstreamUrl(req, backend), {
    method: req.method,
    headers: buildUpstreamHeaders(req),
    body:
      req.method === "GET" || req.method === "HEAD" ? undefined : req.body,
    // Critical: streaming request bodies (e.g. large uploads) need this flag.
    // @ts-expect-error — Workers runtime accepts it; TS types lag.
    duplex: "half",
    redirect: "manual",
  });

  // Pass the body through unchanged (streamed for SSE, single chunk otherwise).
  // Filter hop-by-hop response headers so the Worker doesn't double-set them.
  const responseHeaders = new Headers();
  upstream.headers.forEach((value, key) => {
    if (!HOP_BY_HOP.has(key.toLowerCase())) responseHeaders.set(key, value);
  });

  return new Response(upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers: responseHeaders,
  });
}

// SSE pass-through. Same as proxy() but explicitly disables Cloudflare
// auto-buffering on the response (via Cache-Control: no-transform). Workers
// don't buffer by default, but it's worth being defensive — the failure
// mode is silent (clients receive nothing until the upstream finishes).
export async function proxySse(req: Request, backend: string): Promise<Response> {
  const upstream = await fetch(buildUpstreamUrl(req, backend), {
    method: req.method,
    headers: buildUpstreamHeaders(req),
    body:
      req.method === "GET" || req.method === "HEAD" ? undefined : req.body,
    // @ts-expect-error — see proxy() above.
    duplex: "half",
    redirect: "manual",
  });

  const responseHeaders = new Headers();
  upstream.headers.forEach((value, key) => {
    if (!HOP_BY_HOP.has(key.toLowerCase())) responseHeaders.set(key, value);
  });
  responseHeaders.set("Cache-Control", "no-cache, no-transform");
  responseHeaders.set("X-Accel-Buffering", "no");

  return new Response(upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers: responseHeaders,
  });
}
