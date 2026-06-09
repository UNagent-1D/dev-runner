# Quality Attribute Scenarios — UNAgent Platform

This doc collects our quality attribute scenarios in the classic six-part shape
(Source · Stimulus · Artifact · Environment · Response · Response Measure). Each one
is a target we hold the architecture to, and the **Status** line tells you whether
it's actually wired up in code yet or still on the wishlist.

**Status:** ✅ done · 🔶 partly there · ⬜ planned

---

### Scenario 2 — Service Discovery (pairs with the Load Balancer)

> **Status: ✅ Done.** Implemented at the Kubernetes level and verified live on
> minikube (branch `feat/k8s-minikube`, manifests in `k8s/`). Every workload has a
> `Service`; `conversation-chat` is the HPA-managed, load-balanced service whose
> backend set is kept current by the discovery layer. This is the dynamic-backend
> dependency the Load Balancer scenario relies on.

| Element | Description |
|---|---|
| **Source** | Hundreds of concurrent clients reaching the `conversation-chat` cluster through its `LoadBalancer` Service (`conversation-chat-lb`), plus internal callers (`chat-orch`, `agent-runtime`) that locate `conversation-chat` by DNS name. |
| **Stimulus** | Sustained load pushes CPU past the HPA target (70%); the HorizontalPodAutoscaler scales the `conversation-chat` Deployment out (2 → up to 6), starting new pods. |
| **Artifact** | The Kubernetes service-discovery layer: **CoreDNS** + the `conversation-chat` **Service** and its **EndpointSlice**, reconciled by the EndpointSlice controller and programmed into the data plane by **kube-proxy** (which is also the L4 load balancer the LB scenario relies on). |
| **Environment** | Production-like cluster under peak load (HPA operating between `minReplicas: 2` and `maxReplicas: 6`). |
| **Response** | Each new pod is added to the Service's EndpointSlice **only after it passes its readiness probe** (`GET /api/v1/health`); kube-proxy then updates its rules so the load balancer automatically begins distributing traffic to the new pod — no manual registration, no client or config change, no redeploy. |
| **Response Measure** | A newly-Ready pod starts receiving live traffic **within < 1 s** of passing readiness (endpoint propagation), and **0 requests are routed to a pod before it is Ready** → **zero failed requests** during scale-out. |

**A few details worth knowing:**

- **Mechanism / tactics:** *service registry* (the Service + EndpointSlice is the
  registry; CoreDNS is name resolution) and *readiness gating* (the readiness probe is
  the health check that controls registration). That gate is the architectural reason
  scale-out drops **no** requests: an unready pod is never in the endpoint set.
- **Why it pairs with the Load Balancer.** The `LoadBalancer` Service (via kube-proxy)
  only ever routes to the endpoints discovery publishes. Service discovery is what makes
  the load balancer's backend pool *dynamic* — they are two halves of the same story.
- **Measure realism.** `conversation-chat`'s readiness probe runs `periodSeconds: 10`,
  so a pod is marked Ready within ~5–15 s of starting; **once Ready**, endpoint→data-plane
  propagation is sub-second. The honest, demonstrable number is **"< 1 s after Ready"** —
  measurable live with `kubectl -n unagent get endpointslice -w` against the pod's Ready
  condition. (30 ms is not defensible for k8s endpoint propagation.)
- **Proven in our deploy.** With `conversation-chat` at 2 replicas,
  `kubectl get endpoints conversation-chat` listed both pod IPs registered automatically,
  and LoadBalancer traffic was distributed across both (≈18/17 split) with all `200`s.

**One honest caveat.** We first sketched this around `chat-orch` requesting an
autoscaled `agent-runtime`. But in the implementation the autoscaler (HPA) is on
`conversation-chat`, not `agent-runtime` (which runs `replicas: 1`). So the scenario
targets `conversation-chat` — the service that is actually HPA-managed *and* sits behind
the load balancer. Discovery itself still applies to every service via CoreDNS; only the
elastic-scale half is specific to `conversation-chat`.

---

### Scenario 4 — Circuit Breaker

> **Status: ✅ Done.** `conversation-chat` already runs its LLM calls through a
> real three-state circuit breaker. The code is in
> `internal/clients/llm/circuit_breaker.go`, and it's switched on for real at
> `cmd/server/main.go:76` — not a stub.

| Element | Description |
|---|---|
| **Source** | `conversation-chat`. Every turn it calls out to the LLM provider (OpenRouter, OpenAI-compatible) and has to wait on the answer. |
| **Stimulus** | The provider starts misbehaving — slow replies or outright errors — and the failures pile up past the threshold we set (5 in a row by default). |
| **Artifact** | The circuit breaker that sits in front of the LLM client. It's a drop-in wrapper, so the rest of the service doesn't even know it's there. |
| **Environment** | Business as usual, under load, with the LLM provider degraded but not completely dead. |
| **Response** | Once the failures stack up, the breaker flips to **open** and stops hammering the provider — it just fails fast instead. After it's had time to cool off it lets a single request through to test the waters (**half-open**); if that one works it goes back to **closed**, if it fails it opens straight back up. Nobody has to touch anything. |
| **Response Measure** | Trips after **5 failures in a row**; while open it rejects instantly with no network call; waits **60 s** before probing again; allows **one** probe at a time so we don't stampede a recovering provider; and a quiet stretch of **120 s** with no failures wipes the counter clean. |

**A few details worth knowing:**

- The three states are exactly what you'd expect — **closed** (normal), **open**
  (failing fast), and **half-open** (testing the water with one request). There's a
  longer write-up in `conversation-chat/AGENTS.md` under "LLM circuit breaker".
- Everything's tunable from the environment without touching code:
  `LLM_CB_FAILURE_THRESHOLD`, `LLM_CB_INTERVAL_SECONDS`, `LLM_CB_OPEN_TIMEOUT_SECONDS`,
  and `LLM_CB_MAX_HALF_OPEN_REQUESTS`.
- Only real provider/transport errors count against the breaker. If a call comes back
  fine over the wire but fails our own validation afterwards, that's on us, not the
  provider — so it doesn't trip the breaker.
- The defaults are intentionally generous. A single LLM tool chain can run five rounds
  of ~30 seconds, and we don't want a slow-but-perfectly-fine conversation to look
  like an outage.

**One honest caveat.** We first sketched this scenario around a
`chat-orch → tenant-service` call, but that's not where the breaker ended up — and
really, `chat-orch` doesn't even call `tenant-service` on the request path today
(`TENANT_SERVICE_URL` is loaded but never used; see `chat-orch/TECHNICAL.md §11`).
The breaker we actually built lives one hop downstream in `conversation-chat`, guarding
the LLM — which is the call that most needed protecting anyway.

---

### Scenario 5 — Interoperability (LLM provider)

> **Status: ✅ Done.** Both `chat-orch` (`src/llm.rs`) and `conversation-chat`
> talk to the model through an OpenAI-compatible client. The provider is
> OpenRouter today, selected purely by `OPENAI_BASE_URL` + `OPENAI_DEFAULT_MODEL`
> env vars — no provider-specific code.

| Element | Description |
|---|---|
| **Source** | `chat-orch`. On every turn it needs a model completion — with tool-calling and token streaming — from whatever LLM provider we've pointed it at. |
| **Stimulus** | We send a chat-completion request to OpenRouter (a third-party, OpenAI-compatible gateway), or we decide to swap the model or the whole provider for another OpenAI-compatible one. |
| **Artifact** | The OpenAI-compatible LLM client (`chat-orch/src/llm.rs`), configured entirely through `OPENAI_BASE_URL` and `OPENAI_DEFAULT_MODEL`. |
| **Environment** | Business as usual, provider healthy. The other side is an external system we don't control and never coordinated a schema with — interoperability rests on a shared, de-facto-standard contract (the OpenAI Chat Completions API), not on a private agreement. |
| **Response** | Because both ends speak the same wire contract — `messages`, `tools`/`tool_calls`, and `text/event-stream` streaming — OpenRouter understands the request, runs the tool loop, and streams the completion back. Switching to a different model, or to any other OpenAI-compatible provider, is a change to two env vars; the orchestration code never moves. |
| **Response Measure** | A provider or model swap costs **zero** code changes — only `OPENAI_BASE_URL` / `OPENAI_DEFAULT_MODEL`; **100%** of well-formed completions (including multi-round tool calls and SSE) are understood without translation; and the same client interoperates across **any** OpenAI-compatible provider with no new adapter. |
