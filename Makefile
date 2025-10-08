SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

PROJECT             ?= trust-fabric
export COMPOSE_PROJECT_NAME := $(PROJECT)

COMPOSE_FILE        ?= ops/compose/firefly-besu-aries.yaml
ENV_FILE            ?= ops/compose/.env
COMPOSE             := docker compose --project-name $(PROJECT) -f $(COMPOSE_FILE) --env-file $(ENV_FILE)

FF_DEFAULT_PORT     ?= 5000
FF_DEFAULT_REG_PORT ?= 5100
DX_PORT             ?= 3001
DX_P2P              ?= 41000
ORG                 ?= org1
TIMEOUT_SEC         ?= 120
SMOKE_DATATYPE_NAME ?= smoke
SMOKE_DATATYPE_VER  ?= 1.0.0

# curl primitives
CURL               ?= curl -fsS
CURL_JSON          := $(CURL) -H "Content-Type: application/json"
CURL_INSECURE      := $(CURL) -k        # DX HTTPS is self-signed in dev
CURL_JSON_INSECURE := $(CURL_JSON) -k

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_.-]+:.*?## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /:\t/g' | sort

# -----------------------------
# Lifecycle controls
# -----------------------------
.PHONY: up down restart build pull ps logs nuke validate
up: ## Start local stack (detached)
	$(COMPOSE) up -d --remove-orphans

down: ## Stop stack (preserve volumes)
	$(COMPOSE) down

restart: ## Restart stack
	$(MAKE) down
	$(MAKE) up

build: ## Build images (if local Dockerfiles exist)
	$(COMPOSE) build

pull: ## Pull images
	$(COMPOSE) pull

ps: ## Show service status
	$(COMPOSE) ps

logs: ## Tail logs for all or S=service (make logs S=firefly_org1 TAIL=100)
	$(COMPOSE) logs -f --tail=$${TAIL:-200} $${S:-}

logs-org: ## Tail logs for FireFly org: ORG=org1|reg
	@case "$(ORG)" in \
	  org1) svc=firefly_org1 ;; \
	  reg)  svc=firefly_reg ;; \
	  *) echo "Unsupported ORG=$(ORG)" >&2; exit 1 ;; \
	esac; \
	$(COMPOSE) logs -f --tail=$${TAIL:-200} $$svc

validate: ## Render and validate the effective compose (preflight)
	$(COMPOSE) config

nuke: ## DANGEROUS: remove stack + volumes (use CONFIRM=yes)
	@if [ "$${CONFIRM:-}" != "yes" ]; then \
	  echo "Refusing to destroy volumes. Re-run with: make nuke CONFIRM=yes"; \
	  exit 1; \
	fi
	$(COMPOSE) down -v --remove-orphans

# -----------------------------
# Environment & tooling UX
# -----------------------------
.PHONY: env-dump shell ui doctor
env-dump: ## Show resolved environment
	@echo "# Effective environment (sanitized)"; \
	( set -o allexport; [ -f $(ENV_FILE) ] && source $(ENV_FILE); set +o allexport; \
	  env | grep -E '^(FF_|BESU_|IPFS_|POSTGRES_|ACAPY_|DX_|FF_EVMCONNECT_)' | sort )

shell: ## Open a shell in a container: make shell S=firefly_org1
	@docker exec -it $${S:-firefly_org1} /bin/sh || docker exec -it $${S:-firefly_org1} /bin/bash

ui: ## Open the FireFly UI in browser
	@set +e; PORT=$${FF_UI:-3000}; url="http://localhost:$$PORT"; \
	echo "Opening $$url"; (open $$url || xdg-open $$url || echo "Browse: $$url") >/dev/null 2>&1 || true

doctor: ## Quick diagnostics (files, mounts, ports)
	@echo "== File presence checks =="; \
	for f in \
	  ops/compose/config/dx/config.json \
	  ops/compose/config/dx/certs/ca.pem \
	  ops/compose/config/dx/certs/cert.pem \
	  ops/compose/config/dx/certs/key.pem \
	  ops/compose/config/dx/destinations/data.json \
	  ops/compose/config/dx/peers/data.json \
	  ops/compose/config/evmconnect/org1/config.yaml \
	  ops/compose/config/evmconnect/reg/config.yaml \
	  ops/compose/config/firefly/org1/firefly.core.yaml \
	  ops/compose/config/firefly/reg/firefly.core.yaml \
	; do \
	  if [ -f "$$f" ]; then echo "[OK] $$f"; else echo "[MISS] $$f"; fi; \
	done; \
	echo ""; \
	echo "== Volumes & ports =="; \
	$(MAKE) --no-print-directory ps; \
	echo ""; \
	echo "== Compose mount grep =="; \
	grep -nE "/config\.yaml|firefly\.core\.yaml|config\.json|volumes:" $(COMPOSE_FILE) || true

# -----------------------------
# Port resolver for FireFly orgs
# -----------------------------
define port_for_org
( \
  set -o allexport; [ -f $(ENV_FILE) ] && source $(ENV_FILE); set +o allexport; \
  if [ "$(1)" = "org1" ]; then \
     echo $${FF_ORG1:-$(FF_DEFAULT_PORT)}; \
  elif [ "$(1)" = "reg" ]; then \
     echo $${FF_REG:-$(FF_DEFAULT_REG_PORT)}; \
  else \
     echo "Unknown org $(1)" >&2; exit 1; \
  fi \
)
endef

# -----------------------------
# Health & status (FireFly)
# -----------------------------
.PHONY: wait-ff status-one status wait-all
wait-ff: ## Wait for FireFly (ORG=org1|reg)
	@set -euo pipefail; \
	PORT=$$( $(call port_for_org,$(ORG)) ); \
	URL=$${FF_URL:-http://localhost:$$PORT}; \
	echo "Waiting for FireFly ($(ORG)) at $$URL (timeout $(TIMEOUT_SEC)s) ..."; \
	deadline=$$(( $$(date +%s) + $(TIMEOUT_SEC) )); \
	while true; do \
	  code=$$( $(CURL) -o /dev/null -w "%{http_code}" "$$URL/api/v1/status" || true ); \
	  if [ "$$code" = "200" ]; then \
	    echo "FireFly $(ORG) is up (HTTP 200)."; break; \
	  fi; \
	  if [ $$(date +%s) -ge $$deadline ]; then \
	    echo "Timeout waiting for FireFly $(ORG)"; exit 1; \
	  fi; \
	  sleep 2; \
	done

status-one: ## Show status JSON for ORG=org1|reg
	@PORT=$$( $(call port_for_org,$(ORG)) ); \
	URL=$${FF_URL:-http://localhost:$$PORT}; \
	echo "Status for $(ORG) @ $$URL:"; \
	$(CURL) "$$URL/api/v1/status" | jq .

status: ## Show status for both orgs
	@$(MAKE) --no-print-directory status-one ORG=org1
	@echo ""
	@$(MAKE) --no-print-directory status-one ORG=reg || echo "(Regulator may be read-only or still starting)"

wait-all: ## Wait for both org1 and regulator
	@$(MAKE) --no-print-directory wait-ff ORG=org1
	@$(MAKE) --no-print-directory wait-ff ORG=reg || echo "Regulator not ready yet."

# -----------------------------
# EVMConnect (quick health)
# -----------------------------
.PHONY: evm-health
evm-health: ## Show evmconnect health: make evm-health S=org1|reg
	@case "$${S:-org1}" in \
	  org1) c=evmconnect_org1 ;; \
	  reg)  c=evmconnect_reg  ;; \
	  *) echo "Use S=org1|reg" >&2; exit 1 ;; \
	esac; \
	state=$$(docker inspect -f '{{json .State.Health.Status}}' $$c 2>/dev/null || echo '"unknown"'); \
	echo "$$c health: $$state"

# -----------------------------
# DX (HTTPS API + P2P helpers)
# -----------------------------
.PHONY: wait-dx dx-status dx-p2p-test dx-files-init dx-certs-selfsigned dx-restart
wait-dx: ## Wait for DX HTTPS (/api/v1/status) on localhost:DX_PORT
	@set -euo pipefail; \
	PORT=$${DX_PORT}; \
	URL="https://localhost:$$PORT"; \
	echo "Waiting for DX at $$URL (timeout $(TIMEOUT_SEC)s) ..."; \
	deadline=$$(( $$(date +%s) + $(TIMEOUT_SEC) )); \
	while true; do \
	  code=$$( $(CURL_INSECURE) -o /dev/null -w "%{http_code}" "$$URL/api/v1/status" || true ); \
	  if [ "$$code" = "200" ]; then \
	    echo "DX is up (HTTP 200)."; break; \
	  fi; \
	  if [ $$(date +%s) -ge $$deadline ]; then \
	    echo "Timeout waiting for DX"; exit 1; \
	  fi; \
	  sleep 2; \
	done

dx-status: ## Show DX status JSON (HTTPS, self-signed)
	@$(CURL_INSECURE) "https://localhost:$(DX_PORT)/api/v1/status" | jq .

dx-p2p-test: ## Test TCP to DX P2P (localhost:DX_P2P)
	@echo -n "Checking TCP localhost:$(DX_P2P) ... "; \
	if bash -c '</dev/tcp/127.0.0.1/$(DX_P2P)' >/dev/null 2>&1; then \
	  echo "open"; \
	else \
	  echo "closed"; exit 1; \
	fi

dx-files-init: ## Create DX folders + empty JSON lists (idempotent)
	@mkdir -p ops/compose/config/dx/{certs,destinations,peers}
	@[ -f ops/compose/config/dx/destinations/data.json ] || printf '[]\n' > ops/compose/config/dx/destinations/data.json
	@[ -f ops/compose/config/dx/peers/data.json ] || printf '[]\n' > ops/compose/config/dx/peers/data.json
	@echo "DX file scaffold ready under ops/compose/config/dx"

dx-certs-selfsigned: dx-files-init ## Create self-signed DX HTTPS certs (CN=dx_org1)
	@openssl req -x509 -newkey rsa:2048 -nodes \
	  -keyout ops/compose/config/dx/certs/key.pem \
	  -out    ops/compose/config/dx/certs/cert.pem \
	  -days 365 -subj "/CN=dx_org1"
	@touch ops/compose/config/dx/certs/ca.pem
	@echo "Wrote certs to ops/compose/config/dx/certs"

dx-restart: ## Restart DX container
	$(COMPOSE) restart dx_org1

# -----------------------------
# Aries helpers
# -----------------------------
.PHONY: aries-wait aries-status
aries-wait: ## Wait for Aries agents (issuer + verifier)
	@set -euo pipefail; \
	for svc port in acapy_issuer 8031 acapy_verifier 8041; do \
	  echo "Waiting for $$svc (admin $$port) ..."; \
	  deadline=$$(( $$(date +%s) + $(TIMEOUT_SEC) )); \
	  while true; do \
	    if $(CURL) "http://localhost:$$port/status" >/dev/null 2>&1; then \
	      echo "$$svc ready."; break; \
	    fi; \
	    if [ $$(date +%s) -ge $$deadline ]; then \
	      echo "Timeout waiting for $$svc" >&2; exit 1; \
	    fi; \
	    sleep 2; \
	  done; \
	done

aries-status: ## Show status for Aries issuer & verifier
	@for port in 8031 8041; do \
	  echo "--- Aries admin port $$port"; \
	  $(CURL) "http://localhost:$$port/status" 2>/dev/null || echo "(unavailable)"; \
	done

# -----------------------------
# Smoke test (FireFly org1 write; reg read-only)
# -----------------------------
.PHONY: smoke
smoke: wait-ff ## Smoke test FireFly (write for org1; status only for reg)
	@set -euo pipefail; \
	if [ "$(ORG)" = "reg" ]; then \
	  echo "Read-only smoke for reg:"; \
	  $(MAKE) --no-print-directory status-one ORG=reg; \
	  exit 0; \
	fi; \
	PORT=$$( $(call port_for_org,$(ORG)) ); \
	URL=$${FF_URL:-http://localhost:$$PORT}; \
	echo "Running smoke against $(ORG) at $$URL"; \
	body=$$(cat <<EOF \
{"name":"$(SMOKE_DATATYPE_NAME)","version":"$(SMOKE_DATATYPE_VER)","validator":{"name":"json"}} \
EOF \
); \
	http=$$( $(CURL_JSON) -o /dev/null -w "%{http_code}" -X POST "$$URL/api/v1/datatypes" -d "$$body" || true ); \
	if [ "$$http" != "201" ] && [ "$$http" != "409" ]; then \
	  echo "Smoke failed: HTTP $$http" >&2; exit 1; \
	fi; \
	echo "Smoke test passed (HTTP $$http)."

# -----------------------------
# Bootstrap / dev convenience
# -----------------------------
.PHONY: init-multiparty dev refresh
init-multiparty: ## Placeholder for consortium/org bootstrap
	@echo "Implement multiparty bootstrap steps here if required."

dev: up wait-dx wait-all status ## Bring stack up and display statuses (DX + orgs)

refresh: pull up wait-dx wait-all status ## Pull images and restart
