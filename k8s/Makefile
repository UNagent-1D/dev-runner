# Kubernetes (minikube) bring-up for the dev-runner platform.
# Implements: MongoDB replication (email-mongo rs0), service discovery,
# conversation-chat cluster+replication (HPA), and load balancers.
#
# Usage:  make start  build  deploy  secret  tunnel  status  verify  netcheck  clean
# Run from the umbrella root:  make -C k8s <target>

NS         := unagent
ROOT       := ..
KUBECTL    := kubectl
# configMapGenerator reads init SQL/migrations from above k8s/, so the default
# load restrictor must be relaxed. Render then apply.
KUSTOMIZE  := $(KUBECTL) kustomize --load-restrictor LoadRestrictionsNone platform

# Locally-built images:  name -> build context (relative to umbrella root)
IMAGES := \
  chat-orch:chat-orch \
  conversation-chat:conversation-chat \
  agent-runtime:agent-runtime \
  tenant:Tenant \
  hospital-mock:Hospital-MP \
  compliance:Compliance \
  email-send:UN_email_send_ms \
  user-auth:User-Auth \
  frontend:FrontEnd \
  rabbitmq:UN_message_broker_mb

.PHONY: start
start:   ## Start minikube (docker driver) + Cilium CNI + required addons
	# Cilium (eBPF) ENFORCES NetworkPolicy — the network segmentation in
	# network/networkpolicies.yaml. minikube's default kindnet CNI does NOT, so
	# policies would be silently ignored. The CNI is fixed at cluster creation:
	# an existing kindnet profile must be deleted first (`minikube delete`), then
	# rerun `make start` + `make build` (images live in minikube's daemon).
	minikube start --driver=docker --cpus=4 --memory=8192 --disk-size=40g --cni=cilium
	minikube addons enable metrics-server   # REQUIRED for the conversation-chat HPA
	minikube addons enable default-storageclass
	@echo ">> waiting for Cilium (NetworkPolicy enforcement) to be ready..."
	# Poll for the DaemonSet to appear (minikube creates it just after start
	# returns; `kubectl wait` errors out if it runs before the pods exist), then
	# wait for the rollout. A genuinely kindnet cluster never grows ds/cilium →
	# we fail loudly so policies are never silently unenforced.
	@for i in $$(seq 1 60); do $(KUBECTL) -n kube-system get ds/cilium >/dev/null 2>&1 && break; sleep 2; done
	@$(KUBECTL) -n kube-system get ds/cilium >/dev/null 2>&1 \
	  || { echo "!! No Cilium DaemonSet — the cluster is on kindnet, which IGNORES NetworkPolicy."; \
	       echo "!! Run 'minikube delete' then 'make start' again."; exit 1; }
	@$(KUBECTL) -n kube-system rollout status ds/cilium --timeout=240s

.PHONY: build
build:   ## Build all local images straight into minikube's docker daemon
	@eval $$(minikube docker-env); \
	set -e; \
	for pair in $(IMAGES); do \
	  name=$${pair%%:*}; ctx=$${pair#*:}; \
	  echo ">> building unagent/$$name:local from $(ROOT)/$$ctx"; \
	  docker build -t unagent/$$name:local "$(ROOT)/$$ctx"; \
	done; \
	echo ">> images in minikube:"; minikube image ls | grep unagent || true

.PHONY: deploy
deploy:  ## Render + apply all manifests
	$(KUSTOMIZE) | $(KUBECTL) apply -f -
	@echo ">> waiting for the replica-set init + DB migrations..."
	-$(KUBECTL) -n $(NS) wait --for=condition=complete job/email-mongo-rs-init --timeout=180s
	-$(KUBECTL) -n $(NS) wait --for=condition=complete job/tenant-migrate    --timeout=180s
	-$(KUBECTL) -n $(NS) wait --for=condition=complete job/tenant-seed       --timeout=180s

.PHONY: secret
secret:  ## Inject REAL secret values from the umbrella .env (optional; overrides placeholders)
	$(KUBECTL) create secret generic platform-secrets -n $(NS) \
	  --from-env-file=$(ROOT)/.env --dry-run=client -o yaml | $(KUBECTL) apply -f -

.PHONY: tunnel
tunnel:  ## Assign EXTERNAL-IPs to the LoadBalancer Services (needs sudo; run in a separate terminal)
	minikube tunnel

.PHONY: status
status:  ## Show pods, services, HPA, and the replica-set state
	$(KUBECTL) -n $(NS) get pods -o wide
	@echo; $(KUBECTL) -n $(NS) get svc
	@echo; $(KUBECTL) -n $(NS) get hpa

.PHONY: verify
verify:  ## Prove the 4 patterns
	@echo "== Pattern #1: MongoDB replication =="
	$(KUBECTL) -n $(NS) exec email-mongo-0 -- mongosh --quiet --eval \
	  'rs.status().members.map(m => m.name + "=" + m.stateStr)'
	@echo "== Pattern #2: service discovery (DNS) =="
	$(KUBECTL) -n $(NS) exec deploy/chat-orch -- sh -c 'nslookup conversation-chat 2>/dev/null || getent hosts conversation-chat'
	@echo "== Pattern #3: cluster + replication (HPA + endpoints) =="
	$(KUBECTL) -n $(NS) get hpa conversation-chat
	$(KUBECTL) -n $(NS) get endpoints conversation-chat
	@echo "== Pattern #4: load balancers =="
	$(KUBECTL) -n $(NS) get svc conversation-chat-lb frontend

.PHONY: netcheck
netcheck:  ## Prove segmentation: same-zone ALLOWED, cross-zone DENIED (ephemeral netshoot)
	@$(KUBECTL) -n kube-system get pods -l k8s-app=cilium --no-headers >/dev/null 2>&1 \
	  && echo ">> Cilium present — NetworkPolicy is enforced" \
	  || echo "!! WARNING: no cilium pods found — policies may NOT be enforced (kindnet?)"
	@printf ">> NetworkPolicies installed (expect 12): "; $(KUBECTL) -n $(NS) get networkpolicy --no-headers | wc -l
	@echo ">> probing from real pods (ephemeral netshoot inherits the pod's network identity):"
	@probe() { \
	  src=$$($(KUBECTL) -n $(NS) get pod -l app=$$1 --field-selector=status.phase=Running \
	          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	  [ -z "$$src" ] && { printf '   [skip] no running %s pod\n' "$$1"; return; }; \
	  out=$$($(KUBECTL) -n $(NS) debug "$$src" -iq --image=nicolaka/netshoot \
	          -- nc -zv -w4 "$$2" "$$3" 2>&1); \
	  echo "$$out" | grep -q succeeded && verdict=REACHABLE || verdict=blocked; \
	  printf '   %-42s expect %-5s -> %s\n' "$$1 -> $$2:$$3" "$$4" "$$verdict"; \
	}; \
	probe tenant            tenant-postgres 5432  ALLOW; \
	probe conversation-chat redis           6379  ALLOW; \
	probe chat-orch         compliance      8091  ALLOW; \
	probe chat-orch         tenant-postgres 5432  DENY; \
	probe frontend          redis           6379  DENY; \
	probe agent-runtime     email-mongo     27017 DENY
	@echo ">> ALLOW rows must be REACHABLE; DENY rows must be blocked. (Tip: hubble observe -n $(NS) --verdict DROPPED)"

# ---------------------------------------------------------------------------
# GKE (project unagent-498915) — overlays/gke-{prod,dev}, one namespace per env.
# Order per env:  gke-secret -> gke-build (once, shared tag) -> gke-deploy
# The minikube targets above are untouched; status/verify/netcheck/failover
# work against GKE with NS=unagent-<env>.
AR      := us-central1-docker.pkg.dev/unagent-498915/unagent
TAG     ?= $(shell git -C $(ROOT) rev-parse --short HEAD)
ENV     ?= prod
GKE_NS  := unagent-$(ENV)
GKE_KUSTOMIZE = $(KUBECTL) kustomize --load-restrictor LoadRestrictionsNone overlays/gke-$(ENV)

.PHONY: gke-build
gke-build:  ## Build + push all images to Artifact Registry as :$(TAG) (host docker, not minikube's)
	@set -e; \
	for pair in $(IMAGES); do \
	  name=$${pair%%:*}; ctx=$${pair#*:}; \
	  echo ">> building $(AR)/$$name:$(TAG) from $(ROOT)/$$ctx"; \
	  docker build -t $(AR)/$$name:$(TAG) "$(ROOT)/$$ctx"; \
	  docker push $(AR)/$$name:$(TAG); \
	done

.PHONY: gke-secret
gke-secret:  ## Map .env.$(ENV) -> platform-secrets in unagent-$(ENV) (run before first gke-deploy)
	$(ROOT)/scripts/gke-secrets.sh $(ENV)

.PHONY: gke-deploy
gke-deploy:  ## Render overlays/gke-$(ENV), assert GKE-safety, pin :$(TAG), apply, wait for jobs
	@$(GKE_KUSTOMIZE) > /tmp/gke-render-$(ENV).yaml
	@grep -q "namespace: $(GKE_NS)" /tmp/gke-render-$(ENV).yaml \
	  || { echo "!! namespace rename to $(GKE_NS) failed"; exit 1; }
	@! grep -q "imagePullPolicy: Never" /tmp/gke-render-$(ENV).yaml \
	  || { echo "!! imagePullPolicy: Never leaked into the GKE render"; exit 1; }
	@! grep -q "image: unagent/" /tmp/gke-render-$(ENV).yaml \
	  || { echo "!! a local :local image leaked into the GKE render"; exit 1; }
	@! grep -q "type: LoadBalancer" /tmp/gke-render-$(ENV).yaml \
	  || { echo "!! a LoadBalancer Service leaked into the GKE render"; exit 1; }
	@! grep -q "sk-or-v1-REPLACE_ME" /tmp/gke-render-$(ENV).yaml \
	  || { echo "!! placeholder Secret leaked into the GKE render"; exit 1; }
	@# one-shot Jobs carry the image tag in an immutable pod template — drop
	@# completed ones so a new TAG can re-apply (all three are idempotent)
	-$(KUBECTL) -n $(GKE_NS) delete job email-mongo-rs-init tenant-migrate tenant-seed --ignore-not-found
	sed "s/:GKE_TAG/:$(TAG)/g" /tmp/gke-render-$(ENV).yaml | $(KUBECTL) apply -f -
	@echo ">> waiting for the replica-set init + DB migrations ($(GKE_NS))..."
	-$(KUBECTL) -n $(GKE_NS) wait --for=condition=complete job/email-mongo-rs-init --timeout=300s
	-$(KUBECTL) -n $(GKE_NS) wait --for=condition=complete job/tenant-migrate    --timeout=300s
	-$(KUBECTL) -n $(GKE_NS) wait --for=condition=complete job/tenant-seed       --timeout=300s

.PHONY: failover
failover:  ## Demonstrate replica-set re-election: delete the current PRIMARY pod
	@p=$$($(KUBECTL) -n $(NS) exec email-mongo-0 -- mongosh --quiet --eval \
	  'rs.status().members.find(m=>m.stateStr=="PRIMARY").name' | sed "s/\..*//"); \
	echo "current PRIMARY: $$p — deleting it"; $(KUBECTL) -n $(NS) delete pod $$p; \
	sleep 12; $(KUBECTL) -n $(NS) exec email-mongo-0 -- mongosh --quiet --eval \
	  'rs.status().members.map(m => m.name + "=" + m.stateStr)'

.PHONY: clean
clean:   ## Delete the namespace (all workloads + PVCs)
	-$(KUBECTL) delete namespace $(NS)

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
