# Entry points for humans, agents, and CI. Run `make help` for the list.

SHELL := /bin/bash
PORT ?= $(or $(CONDUCTOR_PORT),4000)

# Prefix for recipe lines that run mix. Sources .env (see .env.example) with
# shell syntax, then restores the variables that were already exported, so the
# shell environment wins over .env.
LOAD_ENV = saved="$$(export -p)"; if [ -f .env ]; then set -a; . ./.env; set +a; eval "$$saved"; fi

.PHONY: help setup db-up db-down db-reset ollama dev iex test check check-quiet fmt

help: ## Show this help
	@grep -hE '^[a-z-]+:.*## ' Makefile | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

setup: db-up ## Install deps and create + migrate the dev and test databases
	@command -v mise >/dev/null && mise install || true
	$(LOAD_ENV); cd backend && mix deps.get && mix ecto.setup
	$(LOAD_ENV); cd backend && MIX_ENV=test mix do ecto.create --quiet + ecto.migrate --quiet

db-up: ## Start Postgres (pgvector) in Docker
	docker compose up -d --wait db

db-down: ## Stop Postgres (data is kept in a Docker volume)
	docker compose down

db-reset: db-up ## Drop and recreate this workspace's dev database
	$(LOAD_ENV); cd backend && mix ecto.reset

# The defaults match Knowseek.Embeddings.Ollama.
ollama: ## Check that a native Ollama runs, then pull $OLLAMA_MODEL (for EMBEDDINGS_ADAPTER=ollama)
	@command -v ollama >/dev/null || { echo "Ollama is not installed. Run: brew install ollama"; exit 1; }
	@$(LOAD_ENV); url="$${OLLAMA_URL:-http://localhost:11434}"; model="$${OLLAMA_MODEL:-bge-m3}"; \
	curl -sf -m 2 "$$url/api/version" >/dev/null || { echo "Ollama does not answer on $$url. Run: brew services start ollama"; exit 1; }; \
	echo "ollama pull $$model"; OLLAMA_HOST="$$url" ollama pull "$$model"

dev: db-up ## Run the API server on $PORT (defaults to $CONDUCTOR_PORT, then 4000)
	$(LOAD_ENV); cd backend && mix do ecto.create --quiet + ecto.migrate --quiet
	$(LOAD_ENV); cd backend && PORT=$(PORT) mix phx.server

iex: db-up ## Run the API server inside an IEx shell
	$(LOAD_ENV); cd backend && PORT=$(PORT) iex -S mix phx.server

test: db-up ## Run the test suite
	$(LOAD_ENV); cd backend && mix test

check: db-up ## Compile with warnings as errors, format, credo, test. Run before you finish a task.
	$(LOAD_ENV); cd backend && mix precommit

check-quiet: db-up ## Same as check, but print only failures (full log: backend/_build/check.log)
	@$(LOAD_ENV); cd backend && if mix precommit > _build/check.log 2>&1; then \
		echo "make check: OK ($$(grep '^Result:' _build/check.log | tail -1))"; \
	else \
		echo "make check: FAILED. Last 80 lines of backend/_build/check.log:"; \
		tail -n 80 _build/check.log; exit 1; \
	fi

fmt: ## Format Elixir code
	cd backend && mix format
