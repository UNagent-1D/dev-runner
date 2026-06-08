# Kubernetes deployment (minikube)

Full-stack Kubernetes deployment of the dev-runner platform, implementing four
architecture patterns on top of the **existing** services (no new services).
Verified end-to-end on minikube (docker driver).

## The four patterns

| # | Pattern | Where | Files |
|---|---------|-------|-------|
| 1 | **Replication** | `email-mongo` as a 3-member MongoDB replica set `rs0` (Compliance + email-send write here) | `data/email-mongo.yaml` |
| 2 | **Service discovery** | One `Service` per workload; consumers dial DNS names via CoreDNS (compose names map 1:1) | every `Service` |
| 3 | **Cluster + replication** | `conversation-chat` (the LLM-connected service) as an HPA-managed multi-replica Deployment | `apps/conversation-chat.yaml` |
| 4 | **Load balancer** | `conversation-chat-lb` + `frontend` `Service type: LoadBalancer` | `apps/conversation-chat.yaml`, `apps/frontend.yaml` |

`conversation-chat` was chosen for the cluster pattern (over `chat-orch`) because
its state is externalized to Redis + conversation-mongo and its RabbitMQ worker
uses competing-consumers, so replicas are interchangeable. `chat-orch` stays at
`replicas: 1` (in-memory SessionStore + per-process SSE).

## Layout

```
k8s/
  kustomization.yaml      namespace: unagent + configMapGenerators (init SQL/migrations)
  Makefile                start / build / deploy / verify / failover / clean
  base/                   namespace, platform ConfigMap, platform Secret
  data/                   email-mongo (rs0), conversation-mongo, redis, rabbitmq, {tenant,hospital}-postgres
  jobs/                   tenant-migrate, tenant-seed
  apps/                   all 11 application workloads
```

## Prerequisites

- **Docker** (running), **kubectl** (v1.27+), **minikube** (v1.30+).
- **RAM:** a full bring-up wants `--memory 8192`. The Rust/Java image builds are
  memory-hungry; close other heavy containers first.
- **Kernel `xt_comment` module** (Linux hosts): minikube's bridge CNI needs the
  iptables `comment` match. Check it is loadable:
  ```bash
  modprobe -n -v xt_comment   # must NOT say "not found"
  ```
  If it says *not found* on Arch, your running kernel's modules were removed by a
  kernel upgrade — see [Troubleshooting](#troubleshooting) for the **no-reboot fix**.

## How to run it

From the umbrella root:

```bash
# 1. Cluster + addons (metrics-server is REQUIRED for the HPA in pattern #3)
make -C k8s start

# 2. Build all 10 local images straight into minikube's docker daemon
make -C k8s build

# 3. Render + apply everything (namespace → config → data → jobs → apps)
make -C k8s deploy

# 4. (optional) inject real secrets — set OPENROUTER_API_KEY for live LLM replies
make -C k8s secret

# 5. Status + proof of all four patterns
make -C k8s status
make -C k8s verify
make -C k8s failover     # kills the mongo PRIMARY → shows re-election
```

What the Makefile handles for you:

- **`kubectl apply -k` does NOT work here.** The `configMapGenerator`s read init
  SQL/migrations from *above* `k8s/`, so kustomize's load restrictor rejects a plain
  `-k`. `make deploy` renders with
  `kubectl kustomize --load-restrictor LoadRestrictionsNone . | kubectl apply -f -`.
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

## Troubleshooting

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
