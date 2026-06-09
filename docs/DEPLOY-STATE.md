# Deploy state — GKE (2026-06-09)

Single source of truth for what runs where. The Railway deployment this doc
used to describe was **torn down on 2026-06-09** (project `remarkable-comfort`
deleted, volumes included) after both environments were verified live on GKE.

## Topology

- **GCP project:** `unagent-498915` (owner julianandresvaquiro6@gmail.com;
  juan400reyesloaiza@gmail.com + danidiaztech@gmail.com have `roles/editor`).
- **Cluster:** `unagent` — GKE Standard, zonal `us-central1-a`, 3× e2-standard-2,
  **Dataplane V2** (Cilium → the 12 NetworkPolicies are enforced), release
  channel regular. Built-in metrics-server feeds the conversation-chat HPA.
- **Namespaces:** `unagent-prod` (apex) and `unagent-dev` — same manifests,
  per-env values from `k8s/overlays/gke-{prod,dev}`.
- **Images:** `us-central1-docker.pkg.dev/unagent-498915/unagent/<svc>:<git-sha>`
  — currently `:6783995` everywhere. Build+push with `make -C k8s gke-build TAG=…`.
- **Frontend:** Cloudflare Worker `unagent-gateway[-dev]` serves the SPA and
  proxies all 5 BACKEND_* vars to the env's api hostname. The in-cluster
  `frontend` nginx is the single gateway behind each GCLB (its routing table
  mirrors the Worker's).

## Public entry points

| Env  | Site (Worker)      | API origin (GCLB Ingress)  | Static IP        |
|------|--------------------|----------------------------|------------------|
| prod | unagent.site       | api.unagent.site (HTTPS)   | 34.54.189.213    |
| dev  | dev.unagent.site   | api-dev.unagent.site       | 8.233.227.226    |

DNS: two **DNS-only** (grey cloud) A records in the Cloudflare zone. The
Google ManagedCertificates are Active; SSE survives the GCLB via
`BackendConfig timeoutSec: 86400`.

## Bring-up / redeploy

```
make -C k8s gke-secret ENV=prod        # .env.prod -> platform-secrets (once / on rotation)
make -C k8s gke-build  TAG=<sha>       # build + push 10 images
make -C k8s gke-deploy ENV=prod TAG=<sha>
# same with ENV=dev; verify with:
make -C k8s netcheck NS=unagent-prod   # 6 probes: 3 ALLOW + 3 DENY
make -C k8s verify   NS=unagent-prod   # 4 patterns
```

## Verified on 2026-06-09 (both envs)

- Chat turn with hospital tool-calling, reply delivered over SSE through
  Worker → GCLB → nginx → chat-orch (session affinity holds on Dataplane V2).
- Login (`admin@demo.com`, seeded) returns app_admin JWT; `/stats/kpis` counts
  turns; email-mongo rs0 = PRIMARY + 2 SECONDARY; redis-1 replica link up;
  HPA live; all PVCs Bound; netcheck 6/6 in both namespaces.
- Secure channel ON in both envs (`BACKEND_CHANNEL_ENABLED=true`).
- Telegram: **dev bot live** (single poller = `chat-orch-telegram` Deployment;
  the main chat-orch pods are token-less by design — 2 replicas would 409).

## Known notes / follow-ups

- **Prod Telegram token is invalid (401 from Telegram).** Same value Railway
  used, so prod Telegram was already dead pre-migration. Fix: new BotFather
  token into `.env.prod`, re-run `make -C k8s gke-secret ENV=prod`, then
  `kubectl -n unagent-prod rollout restart deploy/chat-orch-telegram`.
- **INTERNAL_API_KEY is the `dev-internal-key` default** (Railway parity).
  Rotate by setting it in `.env.{prod,dev}` + re-running gke-secret + restart.
- Cross-namespace nicety: `allow-public-*` policies admit any in-cluster
  source on 80/8082; tighten later if desired.
- Costs ≈ $147/mo nodes + ~$36/mo two GCLBs + ~12 small PDs.
- GKE pulls of `nicolaka/netshoot` (netcheck) come from Docker Hub — first
  probe per node is slow; a one-off `blocked` on an ALLOW row is usually the
  image pull, re-run the probe.
