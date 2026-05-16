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

// Build the RequestInit for the upstream fetch. GET / HEAD have no body.
// For POST/PUT/PATCH/DELETE we BUFFER the body (req.arrayBuffer) instead
// of forwarding the ReadableStream — Workers' fetch() doesn't accept the
// `duplex` flag the way the standard Fetch API does, and forwarding a
// stream without it produces "TypeError: When constructing a Request with
// a streaming body, you must set `duplex: 'half'`". Our request bodies
// are small JSON; the buffering cost is negligible.
async function buildUpstreamInit(req: Request): Promise<RequestInit> {
  const init: RequestInit = {
    method: req.method,
    headers: buildUpstreamHeaders(req),
    redirect: "manual",
  };
  if (req.method !== "GET" && req.method !== "HEAD") {
    init.body = await req.arrayBuffer();
  }
  return init;
}

export async function proxy(req: Request, backend: string): Promise<Response> {
  const upstream = await fetch(
    buildUpstreamUrl(req, backend),
    await buildUpstreamInit(req),
  );

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
  const upstream = await fetch(
    buildUpstreamUrl(req, backend),
    await buildUpstreamInit(req),
  );

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
