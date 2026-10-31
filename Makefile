# Entry points for humans, agents, and CI. Run `make help` for the list.

SHELL := /bin/bash
PORT ?= $(or $(CONDUCTOR_PORT),4000)

# Task worktrees live next to the main checkout: ../knowseek-worktrees/<name>.
# The main checkout is found through git, so this also works inside a worktree.
MAIN_REPO := $(shell dirname "$$(git rev-parse --path-format=absolute --git-common-dir)")
WORKTREES ?= $(abspath $(MAIN_REPO)/../knowseek-worktrees)
BASE ?= origin/main

# Prefix for recipe lines that run mix. Sources .env (see .env.example) with
# shell syntax, then restores the variables that were already exported, so the
# shell environment wins over .env.
LOAD_ENV = saved="$$(export -p)"; if [ -f .env ]; then set -a; . ./.env; set +a; eval "$$saved"; fi

.PHONY: help setup db-up db-down db-reset ollama start api-run dev web iex test check check-migrations guard-main check-quiet web-check fmt worktree worktree-rm

help: ## Show this help
	@grep -hE '^[a-z-]+:.*## ' Makefile | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

setup: db-up ollama ## Install deps and create + migrate the dev and test databases
	@command -v mise >/dev/null && mise install || true
	$(LOAD_ENV); cd backend && mix deps.get && mix ecto.setup
	$(LOAD_ENV); cd backend && MIX_ENV=test mix do ecto.create --quiet + ecto.migrate --quiet
	cd frontend && npm install

db-up: ## Start Postgres (pgvector) in Docker
	docker compose up -d --wait db

db-down: ## Stop Postgres and the app container (data is kept in a Docker volume)
	docker compose --profile app down

db-reset: db-up ollama ## Drop and recreate this workspace's dev database
	$(LOAD_ENV); cd backend && mix ecto.reset

# The defaults match Knowseek.Embeddings.Ollama. Does nothing for other adapters.
# Runs after db-up in dev, iex, start, and setup. Not part of test or check.
ollama: ## Check that Ollama runs and pull $OLLAMA_MODEL (skipped if EMBEDDINGS_ADAPTER is not ollama)
	@$(LOAD_ENV); scripts/ensure-ollama

start: db-up ollama ## Run the API and the web UI together in one terminal (Ctrl-C stops both)
	$(LOAD_ENV); cd backend && mix do ecto.create --quiet + ecto.migrate --quiet
	@$(LOAD_ENV); PORT=$(PORT) exec scripts/start

api-run: # internal: used by scripts/start
	$(LOAD_ENV); cd backend && PORT=$(PORT) mix phx.server

dev: db-up ollama ## Run the API server on $PORT (defaults to $CONDUCTOR_PORT, then 4000)
	$(LOAD_ENV); cd backend && mix do ecto.create --quiet + ecto.migrate --quiet
	$(LOAD_ENV); cd backend && PORT=$(PORT) mix phx.server

web: ## Run the web UI on $PORT+1 (proxies /api to the API on $PORT). Run `make dev` too.
	cd frontend && API_PORT=$(PORT) WEB_PORT=$$(($(PORT) + 1)) npm run dev

iex: db-up ollama ## Run the API server inside an IEx shell
	$(LOAD_ENV); cd backend && PORT=$(PORT) iex -S mix phx.server

test: db-up ## Run the test suite. Single file: make test ARGS=test/knowseek/search_test.exs
	$(LOAD_ENV); cd backend && mix test $(ARGS)

guard-main: ## Fail if the main checkout has uncommitted changes (an agent edited it by mistake). One line when clean.
	@scripts/assert-main-clean

check-migrations: ## Check migration file names: unique versions, generator format, none in the future
	@scripts/check-migrations

check: db-up guard-main check-migrations web-check ## Backend (compile, format, credo, test) and frontend (types, format, test). Run before you finish a task.
	$(LOAD_ENV); cd backend && mix precommit

check-quiet: db-up guard-main check-migrations ## Same as check, but print only failures (full logs: backend/_build/check.log, backend/_build/web-check.log)
	@mkdir -p backend/_build
	@if $(MAKE) --no-print-directory web-check > backend/_build/web-check.log 2>&1; then \
		echo "make check (web): OK"; \
	else \
		echo "make check (web): FAILED. Last 80 lines of backend/_build/web-check.log:"; \
		tail -n 80 backend/_build/web-check.log; exit 1; \
	fi
	@$(LOAD_ENV); cd backend && if mix precommit > _build/check.log 2>&1; then \
		echo "make check: OK ($$(grep '^Result:' _build/check.log | tail -1))"; \
	else \
		echo "make check: FAILED. Last 80 lines of backend/_build/check.log:"; \
		tail -n 80 _build/check.log; exit 1; \
	fi

web-check: ## Typecheck, format check, and test the web UI
	@cd frontend && { [ node_modules/.package-lock.json -nt package-lock.json ] || npm ci --prefer-offline --no-audit --no-fund; } && npm run check

fmt: ## Format Elixir and web UI code
	cd backend && mix format
	cd frontend && npm run format

# One worktree per task, with its own branch and databases. KNOWSEEK_WORKSPACE
# in the worktree's .env names the databases (see backend/config/dev.exs).
# Runs from any checkout. The branch starts at BASE (default origin/main).
worktree: ## Create a task worktree + branch + databases: make worktree NAME=task-014-one-hit
	@[[ "$(NAME)" =~ ^[a-z0-9][a-z0-9-]{0,30}$$ ]] || { echo "Usage: make worktree NAME=<lowercase-letters-digits-dashes, max 31 chars>"; exit 1; }
	git fetch origin main
	git worktree add -b "$(NAME)" "$(WORKTREES)/$(NAME)" "$(BASE)"
	@if [ -f "$(MAIN_REPO)/.env" ]; then cp "$(MAIN_REPO)/.env" "$(WORKTREES)/$(NAME)/.env"; fi
	@echo "KNOWSEEK_WORKSPACE=$(NAME)" >> "$(WORKTREES)/$(NAME)/.env"
	@# Task worktrees do not need Ollama (tests pin hashing). Opt in by editing .env. ADR 0016.
	@grep -qE '^[[:space:]]*(export[[:space:]]+)?EMBEDDINGS_ADAPTER=' "$(WORKTREES)/$(NAME)/.env" || echo "EMBEDDINGS_ADAPTER=hashing" >> "$(WORKTREES)/$(NAME)/.env"
	@$(MAKE) -C "$(WORKTREES)/$(NAME)" setup || { echo "Setup failed. The worktree exists: fix the problem, then run 'make setup' inside $(WORKTREES)/$(NAME)"; exit 1; }
	@echo "Worktree ready: $(WORKTREES)/$(NAME)"

worktree-rm: ## Drop a worktree's databases and remove it (keeps the branch): make worktree-rm NAME=...
	@test -d "$(WORKTREES)/$(NAME)" || { echo "No worktree at $(WORKTREES)/$(NAME)"; exit 1; }
	cd "$(WORKTREES)/$(NAME)/backend" && KNOWSEEK_WORKSPACE="$(NAME)" mix ecto.drop --quiet && KNOWSEEK_WORKSPACE="$(NAME)" MIX_ENV=test mix ecto.drop --quiet
	git worktree remove --force "$(WORKTREES)/$(NAME)"
