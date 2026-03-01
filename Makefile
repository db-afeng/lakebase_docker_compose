.PHONY: dev-local dev-lakebase dev-down dev-destroy dev-status lakebase-init refresh-token

# ---------------------------------------------------------------------------
# Local development (PostgreSQL container)
# ---------------------------------------------------------------------------

dev-local:
	docker compose --profile local up --build

# ---------------------------------------------------------------------------
# Lakebase development (ephemeral branch from production)
# ---------------------------------------------------------------------------

lakebase-init:
	@./scripts/db_init.sh

dev-lakebase:
	@./scripts/lakebase-branch.sh
	docker compose --env-file .env.lakebase up --build

refresh-token:
	@./scripts/lakebase-branch.sh --refresh-only

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

dev-down:
	docker compose --profile local down

dev-destroy:
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

dev-status:
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
