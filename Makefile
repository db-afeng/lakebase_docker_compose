.PHONY: help dev-local dev-lakebase dev-down dev-destroy dev-status lakebase-init refresh-token

.DEFAULT_GOAL := help

help: ## Show this help
	@printf '\nUsage: make <target>\n\n'
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
		awk -F ':.*## ' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ''

# ---------------------------------------------------------------------------
# Local development (PostgreSQL container)
# ---------------------------------------------------------------------------

dev-local: ## Start app with local PostgreSQL container
	docker compose --profile local up --build -d

# ---------------------------------------------------------------------------
# Lakebase development (ephemeral branch from production)
# ---------------------------------------------------------------------------

lakebase-init: ## Provision a new Lakebase database (first-time setup)
	@./scripts/db_init.sh

dev-lakebase: ## Start app with an ephemeral Lakebase branch
	@./scripts/lakebase-branch.sh
	docker compose --env-file .env.lakebase up --build -d

refresh-token: ## Refresh the Lakebase OAuth token without restarting
	@./scripts/lakebase-branch.sh --refresh-only

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

dev-down: ## Stop containers (keeps volumes)
	docker compose --profile local down

dev-destroy: ## Stop containers, delete Lakebase branch, remove .env.lakebase
	@if [ -f .env.lakebase ]; then \
		. ./lakebase.config; \
		BRANCH_PATH=$$(grep '^LAKEBASE_BRANCH_PATH=' .env.lakebase | cut -d= -f2); \
		if [ -n "$$BRANCH_PATH" ]; then \
			PROFILE_FLAG=""; \
			if [ -n "$$LAKEBASE_PROFILE" ] && [ "$$LAKEBASE_PROFILE" != "DEFAULT" ]; then \
				PROFILE_FLAG="-p $$LAKEBASE_PROFILE"; \
			fi; \
			echo "Deleting Lakebase branch: $$BRANCH_PATH"; \
			databricks postgres delete-branch "$$BRANCH_PATH" $$PROFILE_FLAG --no-wait || true; \
		fi; \
		rm -f .env.lakebase; \
	else \
		echo "No .env.lakebase found — nothing to destroy"; \
	fi
	docker compose --profile local down

dev-status: ## Show current Lakebase branch info
	@if [ -f .env.lakebase ]; then \
		echo "=== .env.lakebase ==="; \
		grep -v 'DATABASE_URL' .env.lakebase; \
		echo ""; \
		echo "=== Lakebase branch ==="; \
		. ./lakebase.config; \
		BRANCH_PATH=$$(grep '^LAKEBASE_BRANCH_PATH=' .env.lakebase | cut -d= -f2); \
		PROFILE_FLAG=""; \
		if [ -n "$$LAKEBASE_PROFILE" ] && [ "$$LAKEBASE_PROFILE" != "DEFAULT" ]; then \
			PROFILE_FLAG="-p $$LAKEBASE_PROFILE"; \
		fi; \
		databricks postgres get-branch "$$BRANCH_PATH" $$PROFILE_FLAG -o json 2>/dev/null | jq '{name, state: .status.current_state}' || echo "Branch not found"; \
	else \
		echo "Not using Lakebase (no .env.lakebase). Run 'make dev-lakebase' first."; \
	fi
