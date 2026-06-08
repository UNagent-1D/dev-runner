# Kubernetes (minikube) bring-up for the dev-runner platform.
# Implements: MongoDB replication (email-mongo rs0), service discovery,
# conversation-chat cluster+replication (HPA), and load balancers.
#
# Usage:  make start  build  deploy  secret  tunnel  status  verify  clean
# Run from the umbrella root:  make -C k8s <target>

NS         := unagent
ROOT       := ..
KUBECTL    := kubectl
# configMapGenerator reads init SQL/migrations from above k8s/, so the default
# load restrictor must be relaxed. Render then apply.
KUSTOMIZE  := $(KUBECTL) kustomize --load-restrictor LoadRestrictionsNone .

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
start:   ## Start minikube (docker driver) + required addons
	minikube start --driver=docker --cpus=4 --memory=8192 --disk-size=40g
	minikube addons enable metrics-server   # REQUIRED for the conversation-chat HPA
	minikube addons enable default-storageclass

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
