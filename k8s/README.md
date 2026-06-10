# Kubernetes deployment (minikube + GKE)

Full-stack Kubernetes deployment of the dev-runner platform, implementing four
architecture patterns on top of the **existing** services (no new services).
Verified end-to-end on minikube (docker driver) and in production on GKE
(see the GKE section below and `../docs/DEPLOY-STATE.md`).

## The four patterns

| # | Pattern | Where | Files |
|---|---------|-------|-------|
| 1 | **Replication** | `email-mongo` as a 3-member MongoDB replica set `rs0` (Compliance + email-send write here) | `data/email-mongo.yaml` |
| 2 | **Service discovery** | One `Service` per workload; consumers dial DNS names via CoreDNS (compose names map 1:1) | every `Service` |
| 3 | **Cluster + replication** | `conversation-chat` (the LLM-connected service) as an HPA-managed multi-replica Deployment | `apps/conversation-chat.yaml` |
| 4 | **Load balancer** | `conversation-chat-lb` + `frontend` `Service type: LoadBalancer` | `apps/conversation-chat.yaml`, `apps/frontend.yaml` |

`conversation-chat` was chosen for the cluster pattern (over `chat-orch`) because
its state is externalized to Redis + conversation-mongo and its RabbitMQ worker
uses competing-consumers, so replicas are interchangeable.

Other workloads run 2 replicas for availability, each shaped around its state:

- `chat-orch` — active/standby. Its SessionStore + SSE hub are in-memory and
  per-process, so the `chat-orch` Service uses `sessionAffinity: ClientIP` to
  pin all traffic (chat POST + matching SSE stream) to one pod; the spare takes
  over if the active pod dies (sessions are lost — they're in-memory anyway).
- `agent-runtime` — 1 replica: the proxy is stateless but the Telegram jobs
  broker keeps its pending-job registry in process memory (register/wait/
  resolve + the chat_results consumer must share a pod).
- `redis` — primary/replica StatefulSet (`redis-1` runs `--replicaof redis-0`);
  the client-facing `redis` Service pins to `redis-0`, so clients are untouched
  and `redis-1` holds a live copy.

## Layout

```
k8s/
  kustomization.yaml      namespace: unagent + configMapGenerators (init SQL/migrations)
  Makefile                start / build / deploy / verify / netcheck / failover / clean
  base/                   namespace, platform ConfigMap, platform Secret
  data/                   email-mongo (rs0), conversation-mongo, redis, rabbitmq, {tenant,hospital}-postgres
  jobs/                   tenant-migrate, tenant-seed
  apps/                   all 11 application workloads
  network/                NetworkPolicies — the docker-compose "red" segmentation, enforced
```

## Prerequisites

- **Docker** (running), **kubectl** (v1.27+), **minikube** (v1.30+).
- **RAM:** a full bring-up wants `--memory 8192`. The Rust/Java image builds are
  memory-hungry; close other heavy containers first.
- **CNI: Cilium (eBPF).** `make start` brings the cluster up with `--cni=cilium`
  because the [network segmentation](#network-segmentation) requires a CNI that
  enforces `NetworkPolicy` — minikube's default kindnet/bridge CNI **silently
  ignores** it. Cilium enforces policy in eBPF, which also sidesteps the
  iptables/`xt_comment` kernel-module fragility the bridge CNI suffered on Arch.
  It needs a modern kernel with BTF; check:
  ```bash
  test -f /sys/kernel/btf/vmlinux && echo "BTF ok (Cilium viable)"   # kernel >= 5.10, CONFIG_DEBUG_INFO_BTF=y
  ```
  The CNI is fixed at cluster creation. If you have an **existing kindnet
  profile**, delete it first or policies won't be enforced:
  ```bash
  minikube delete        # then `make start` (recreates with Cilium) + `make build`
  ```

## How to run it

From the umbrella root:

```bash
# 1. Cluster + Cilium CNI + addons (metrics-server is REQUIRED for the HPA in
#    pattern #3; Cilium enforces the NetworkPolicy segmentation). If a kindnet
#    profile already exists, `minikube delete` first — see Prerequisites.
make -C k8s start

# 2. Build all 10 local images straight into minikube's docker daemon
make -C k8s build

# 3. Render + apply everything (namespace → config → data → jobs → apps → network)
make -C k8s deploy

# 4. (optional) inject real secrets — set OPENROUTER_API_KEY for live LLM replies
make -C k8s secret

# 5. Status + proof of all four patterns + the network segmentation
make -C k8s status
make -C k8s verify
make -C k8s netcheck     # proves same-zone reachable, cross-zone blocked
make -C k8s failover     # kills the mongo PRIMARY → shows re-election
```

What the Makefile handles for you:

- **`kubectl apply -k` does NOT work here.** The `configMapGenerator`s read init
  SQL/migrations from *above* `k8s/`, so kustomize's load restrictor rejects a plain
  `-k`. `make deploy` renders with
  `kubectl kustomize --load-restrictor LoadRestrictionsNone platform | kubectl apply -f -`
  (the base kustomization lives in `k8s/platform/` so the GKE overlays can
  reference it without a kustomize root cycle).
- **Images** are tagged `unagent/<svc>:local` with `imagePullPolicy: Never`, built
  into minikube's daemon (`eval $(minikube docker-env)`), so nothing is pushed to a
  registry.

### Reaching the LoadBalancer Services (pattern #4)

`type: LoadBalancer` shows `EXTERNAL-IP <pending>` on minikube until a tunnel runs:

```bash
make -C k8s tunnel       # separate terminal, needs sudo → assigns EXTERNAL-IPs
```

No-sudo alternatives:

```bash
minikube service conversation-chat-lb -n unagent --url   # prints a reachable URL
minikube service frontend            -n unagent --url
# or hit the NodePort directly:
curl http://$(minikube ip):$(kubectl -n unagent get svc conversation-chat-lb -o jsonpath='{.spec.ports[0].nodePort}')/api/v1/health
```

## Verifying the patterns

```bash
make -C k8s verify
```

- **#1 Replication** —
  `kubectl -n unagent exec email-mongo-0 -- mongosh --quiet --eval 'rs.status().members.map(m=>m.name+"="+m.stateStr)'`
  → one `PRIMARY` + two `SECONDARY`. `make failover` deletes the primary and shows
  a survivor elected within seconds.
- **#2 Service discovery** —
  `kubectl -n unagent exec deploy/conversation-chat -- getent hosts conversation-chat email-mongo redis rabbitmq`
  resolves each to its ClusterIP.
- **#3 Cluster + replication** — `kubectl -n unagent get hpa conversation-chat`
  shows `cpu: x%/70%`, min 2 / max 6 (needs metrics-server);
  `kubectl -n unagent get endpoints conversation-chat` lists one IP per replica.
- **#4 Load balancer** — repeated requests to the LB return 200 and are distributed
  across the replicas (check both pods' logs).

## Network segmentation

This deployment mirrors the **`docker-compose.yml` network segmentation** (the
"red" / *network* pattern) as enforced `NetworkPolicy`. In compose, each service
joins only the bridge networks it needs and **two services can talk iff they
share a network**. The same boundary is reproduced here.

**How it maps** (`network/networkpolicies.yaml`):

- Every pod carries additive labels `net-<zone>: "true"` — one per compose
  network it belongs to (set in each workload's `spec.template.metadata.labels`;
  Service/Deployment **selectors are untouched**, so nothing about discovery or
  scaling changes).
- `default-deny-ingress` denies all ingress namespace-wide.
- One **intra-zone** policy per zone re-allows ingress between pods sharing that
  zone (all ports — a compose bridge grants full mutual reachability, so this is
  a faithful 1:1 mirror). The **union** of the zones a pod is in == the set of
  pods it shares a network with == the compose matrix, exactly.
- Two **public** allows keyed by `app:` label expose the external entrypoints:
  `frontend:80` and `conversation-chat:8082` (the `conversation-chat-lb`
  LoadBalancer — a k8s-only artifact with no compose `public_net` analog).
- **Egress is intentionally unrestricted.** With egress open, "A reaches B"
  reduces to "B admits A on ingress" (the matrix), and DNS + outbound internet
  (OpenRouter / SendGrid / Telegram) keep working for free. Do **not** add egress
  rules without also allowing kube-dns (UDP/TCP 53) and those external hosts.

**Zones** (compose network → label; `auth_net`/`auth_db_net` are unused in compose):

| Zone label | compose network | Members (`app:`) |
|---|---|---|
| `net-public` | public_net | frontend, chat-orch, grafana |
| `net-orch` | orch_net | frontend, chat-orch, conversation-chat, agent-runtime, tenant, hospital-mock, user-auth, rabbitmq |
| `net-tenant` | tenant_net | frontend, tenant, email-send, user-auth |
| `net-compliance` | compliance_net | frontend, chat-orch, compliance, grafana |
| `net-email` | email_net | email-send, user-auth, email-mongo, email-mongo-rs-init |
| `net-tenant-db` | tenant_db_net | tenant, user-auth, tenant-postgres, tenant-migrate, tenant-seed |
| `net-chat-db` | chat_db_net | conversation-chat, redis, conversation-mongo |
| `net-hospital-db` | hospital_db_net | hospital-mock, hospital-postgres |
| `net-compliance-db` | compliance_db_net | compliance, email-mongo |

**Verify it:**

```bash
make -C k8s netcheck      # same-zone probes REACHABLE, cross-zone probes blocked
kubectl -n unagent get networkpolicy           # 12 policies
hubble observe -n unagent --verdict DROPPED     # watch a denied flow live (Cilium)
```

`netcheck` attaches an ephemeral `netshoot` container to a real source pod (it
inherits that pod's Cilium identity) and runs `nc` against a target — e.g.
`chat-orch → tenant-postgres:5432` is **blocked** (no shared zone) while
`tenant → tenant-postgres:5432` is **reachable**. The four pattern demos
(`make verify` / `make failover`) and the full chat flow are unaffected: they
exercise only same-zone paths (mongo replica-set peers all share `net-email`),
and `kubectl exec` / health probes never traverse the policy dataplane.

## GKE (production)

The same base deploys to GKE through `overlays/gke-{prod,dev}` — one namespace
per environment (`unagent-prod` on `unagent.site`, `unagent-dev` on
`dev.unagent.site`). The overlays retag images to Artifact Registry, flip
`imagePullPolicy`, demote the minikube LoadBalancers to ClusterIP, and add a
GCLB Ingress + Google ManagedCertificate + `BackendConfig` (SSE-safe 86400s
timeout) in front of the frontend nginx gateway, plus a single-replica
`chat-orch-telegram` poller (two pollers would 409 against Telegram).

```bash
make gke-secret ENV=prod                 # .env.prod -> platform-secrets (first time / rotation)
make gke-build  TAG=$(git rev-parse --short HEAD)   # build + push 10 images to AR
make gke-deploy ENV=prod TAG=<same>      # render overlay, assert, apply, wait for jobs
make status  NS=unagent-prod             # the minikube targets work with NS=
make verify  NS=unagent-prod
make netcheck NS=unagent-prod            # NetworkPolicies are ENFORCED (Dataplane V2 = Cilium)
make failover NS=unagent-prod
```

Cluster shape, public IPs, DNS records, and the verified state live in
`../docs/DEPLOY-STATE.md`. The Cloudflare Worker (`../cloudflare-worker/`)
serves the SPA and proxies API paths to `api[-dev].unagent.site`.

## Troubleshooting

- **`make netcheck` shows everything REACHABLE (no DENY rows blocked), or
  `make start` warns Cilium isn't running** — the cluster is on kindnet, which
  ignores `NetworkPolicy`. You reused an old profile. `minikube delete`, then
  `make start` (recreates with `--cni=cilium`) + `make build` + `make deploy`.
- **`calico-node`/`cilium` pods CrashLoop or policies silently not enforced** —
  on a stale Arch kernel (modules removed by an upgrade pre-reboot), the eBPF
  dataplane can fail to load. Confirm `test -f /sys/kernel/btf/vmlinux` and that
  `/lib/modules/$(uname -r)` exists; reboot into the current kernel if not.
- **Pods stuck `ContainerCreating`; coredns never ready; events show
  `bridge CNI failed (add): iptables ... comment ... missing kernel module?`** — the
  host kernel can't load `xt_comment`, which minikube's bridge CNI needs. On Arch
  this usually means the kernel package was upgraded but the machine is still running
  the *old* kernel, so `/lib/modules/$(uname -r)` is missing modules
  (`modprobe xt_comment` → "not found" while `CONFIG_NETFILTER_XT_MATCH_COMMENT=m`).

  **No-reboot fix** (restore the running kernel's modules from pacman's cache):
  ```bash
  PKG=/var/cache/pacman/pkg/linux-$(uname -r | sed 's/-arch/.arch/')-x86_64.pkg.tar.zst
  sudo bsdtar -C / -xpf "$PKG" usr/lib/modules/$(uname -r)
  sudo depmod $(uname -r)
  sudo modprobe xt_comment
  ```
  Then `minikube start` and the pods get networking. (If the cached package is gone,
  reboot into the current kernel instead.)

- **PVCs stuck `Pending` / storage-provisioner `Error: dial 10.96.0.1:443 i/o
  timeout`** — host is starved (high load / heavy swap). Free RAM, then the
  provisioner recovers and PVCs bind.

- **`email-mongo-rs-init` / `tenant-migrate` / `tenant-seed` show `Failed`** — they
  ran before the cluster networking was healthy (e.g. during the CNI issue above) and
  hit their `activeDeadlineSeconds`. Re-run them once the data tier is up:
  ```bash
  kubectl -n unagent delete job email-mongo-rs-init tenant-migrate tenant-seed --ignore-not-found
  make -C k8s deploy
  ```

## Notes / known constraints

- `metrics-server` and `minikube tunnel` are manual prerequisites; without them the
  HPA reads `<unknown>` and the LoadBalancers stay `<pending>`.
- Secrets in `base/secret-platform.yaml` are local-dev defaults; replace
  `OPENROUTER_API_KEY` (via `make secret` or by editing) for live LLM responses.
- `conversation-chat`'s `/api/v1/health` always returns 200, so readiness reflects
  "process up", not dependency health (deps are gated by initContainers at boot).
- This is a local/minikube deliverable and does not replace the Railway prod path.
```
