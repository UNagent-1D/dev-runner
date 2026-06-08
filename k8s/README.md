# Kubernetes deployment (minikube)

Full-stack Kubernetes deployment of the dev-runner platform, implementing four
architecture patterns on top of the **existing** services (no new services).

## The four patterns

| # | Pattern | Where | Files |
|---|---------|-------|-------|
| 1 | **Replication** | `email-mongo` as a 3-member MongoDB replica set `rs0` (Compliance + email-send write here) | `data/email-mongo.yaml` |
| 2 | **Service discovery** | One `Service` per workload; consumers dial DNS names via CoreDNS (compose names map 1:1) | every `*-svc` / `Service` |
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

- Docker (running), `kubectl`, `minikube`.
- Free RAM: a full bring-up wants `--memory 8192`. Building the Rust/Java images
  is memory-hungry; close other apps first.

## Bring-up

```bash
make -C k8s start      # minikube + metrics-server (REQUIRED for the HPA) + storageclass
make -C k8s build      # build all 10 local images into minikube's docker daemon
make -C k8s deploy     # render (relaxed load-restrictor) + apply; waits for rs-init + migrations
make -C k8s secret     # OPTIONAL: inject real secrets from ../.env (set OPENROUTER_API_KEY for live chat)
make -C k8s tunnel     # SEPARATE terminal, needs sudo → assigns EXTERNAL-IPs to the LoadBalancers
make -C k8s status
make -C k8s verify     # prints proof of all 4 patterns
```

> **Note on `kubectl apply -k`:** the `configMapGenerator`s read init SQL and
> migration files from *above* `k8s/`, so a plain `kubectl apply -k k8s/` is
> rejected by kustomize's load restrictor. The Makefile renders with
> `kubectl kustomize --load-restrictor LoadRestrictionsNone . | kubectl apply -f -`.

## Verifying the patterns

- **Replication:** `make -C k8s verify` shows `rs.status()` with one `PRIMARY` +
  two `SECONDARY`. `make -C k8s failover` deletes the primary and shows re-election.
- **Service discovery:** `verify` resolves `conversation-chat` from inside a pod.
- **Cluster + replication:** `kubectl -n unagent get hpa` (needs metrics-server);
  `kubectl -n unagent get endpoints conversation-chat` lists all replica IPs;
  generate CPU load to watch it scale 2→6.
- **Load balancer:** with `minikube tunnel` running, `conversation-chat-lb` and
  `frontend` get EXTERNAL-IPs. No-sudo fallback: `minikube service <svc> -n unagent --url`.

## Troubleshooting

- **Pods stuck `ContainerCreating`; coredns never ready; events show
  `bridge CNI failed (add): iptables ... comment ... missing kernel module?`**
  The host kernel can't load `xt_comment`, which minikube's bridge CNI needs to
  program iptables. On Arch this usually means the kernel package was updated but
  the machine is still running the *old* kernel, so `/lib/modules/$(uname -r)` is
  missing modules (`modprobe xt_comment` → "not found", while
  `CONFIG_NETFILTER_XT_MATCH_COMMENT=m`). **Reboot into the current kernel**, then
  `sudo modprobe xt_comment` should succeed and `minikube start` will network pods.
- **PVCs stuck `Pending` / storage-provisioner `Error: dial 10.96.0.1:443 i/o
  timeout`**: the host is starved (high load / heavy swap). Free RAM or give
  minikube fewer competing neighbors, then `minikube start`.

## Notes / known constraints

- `metrics-server` and `minikube tunnel` are manual prerequisites; without them the
  HPA reads `<unknown>` and the LoadBalancers stay `<pending>`.
- Secrets in `base/secret-platform.yaml` are local-dev defaults; replace
  `OPENROUTER_API_KEY` (via `make secret` or by editing) for live LLM responses.
- This is a local/minikube deliverable and does not replace the Railway prod path.
