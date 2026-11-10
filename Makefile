# Entry points for humans, agents, and CI. Run `make help` for the list.

SHELL := /bin/bash
# API port: the environment or the command line wins, then PORT in .env (set
# per worktree by `make worktree`), then 4000. The web UI runs on PORT+1.
ifeq ($(origin PORT),undefined)
PORT := $(or $(shell [ -f .env ] && sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?PORT=([0-9]+)[[:space:]]*$$/\2/p' .env | tail -n 1),4000)
endif

# Worktrees live next to the main checkout: ../knowseek-worktrees/<name>.
# The main checkout is found through git, so this also works inside a worktree.
MAIN_REPO := $(shell dirname "$$(git rev-parse --path-format=absolute --git-common-dir)")
WORKTREES ?= $(abspath $(MAIN_REPO)/../knowseek-worktrees)
BASE ?= origin/main

# Prefix for recipe lines that run mix. Sources .env (see .env.example) with
# shell syntax, then restores the variables that were already exported, so the
# shell environment wins over .env.
LOAD_ENV = saved="$$(export -p)"; if [ -f .env ]; then set -a; . ./.env; set +a; eval "$$saved"; fi

.PHONY: help setup db-reset ollama start api-run dev web iex test check check-migrations check-migration-roundtrip check-docs check-shell check-security check-secrets check-quiet web-check fmt worktree worktree-rm

help: ## Show this help
	@grep -hE '^[a-z-]+:.*## ' Makefile | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

# The database is a SQLite file per checkout: backend/data/knowseek_dev.db and
# knowseek_test.db (git-ignored, ADR 0030). Nothing runs in Docker for
# development. `mix ecto.migrate` first fetches the sqlite-vec extension
# (`mix sqlite_vec.fetch`, pinned by SHA-256; needs the network once).
setup: ollama ## Install deps, fetch sqlite-vec, and create + migrate the dev and test databases
	@command -v mise >/dev/null && mise install || true
	$(LOAD_ENV); cd backend && mix deps.get && mix ecto.setup
	$(LOAD_ENV); cd backend && MIX_ENV=test mix do ecto.create --quiet + ecto.migrate --quiet
	cd frontend && npm install

db-reset: ollama ## Delete and recreate the dev database (backend/data/knowseek_dev.db), with the seeds
	$(LOAD_ENV); cd backend && mix ecto.reset

# The defaults match Knowseek.Embeddings.Ollama. Does nothing for other adapters.
# Runs in dev, iex, start, db-reset, and setup. Not part of test or check.
ollama: ## Check that Ollama runs and pull $OLLAMA_MODEL (skipped if EMBEDDINGS_ADAPTER is not ollama)
	@$(LOAD_ENV); scripts/ensure-ollama

start: ollama ## Run the API and the web UI together in one terminal (Ctrl-C stops both)
	$(LOAD_ENV); cd backend && mix do ecto.create --quiet + ecto.migrate --quiet
	@$(LOAD_ENV); PORT=$(PORT) exec scripts/start

api-run: # internal: used by scripts/start
	$(LOAD_ENV); cd backend && PORT=$(PORT) mix phx.server

dev: ollama ## Run the API server on $PORT (from the environment, then .env, then 4000)
	$(LOAD_ENV); cd backend && mix do ecto.create --quiet + ecto.migrate --quiet
	$(LOAD_ENV); cd backend && PORT=$(PORT) mix phx.server

web: ## Run the web UI on $PORT+1 (proxies /api to the API on $PORT). Run `make dev` too.
	cd frontend && API_PORT=$(PORT) WEB_PORT=$$(($(PORT) + 1)) npm run dev

iex: ollama ## Run the API server inside an IEx shell
	$(LOAD_ENV); cd backend && PORT=$(PORT) iex -S mix phx.server

test: ## Run the test suite. Single file: make test ARGS=test/knowseek/search_test.exs
	$(LOAD_ENV); cd backend && mix test $(ARGS)

check-migrations: ## Check migration file names: unique versions, generator format, none in the future
	@scripts/check-migrations

check-migration-roundtrip: ## Roll back and re-apply the migrations this branch adds, on an empty database and on one with data from origin/main (slow, not part of check; CI runs it)
	@$(LOAD_ENV); scripts/check-migration-roundtrip

check-docs: ## Check task/ADR numbers, README index rows, Status and Depends on lines, and relative markdown links
	@scripts/check-docs

check-shell: ## ShellCheck scripts/ (needs shellcheck; skipped with a note when it is not installed)
	@if command -v shellcheck >/dev/null; then shellcheck scripts/*; else echo "check-shell: shellcheck not installed (brew install shellcheck), skipped. CI runs it."; fi

check-security: ## Dependency and static security scans: hex.audit, deps.audit, sobelow, npm audit (needs the network; not part of check; CI runs it)
	@scripts/check-security

check-secrets: ## Scan the whole git history for secrets with gitleaks (needs Docker; not part of check; CI runs it)
	@scripts/check-secrets

check: check-migrations check-docs check-shell web-check ## Backend (compile, format, credo, test) and frontend (types, format, test). Run before you finish a task.
	$(LOAD_ENV); cd backend && mix precommit

check-quiet: check-migrations check-docs check-shell ## Same as check, but print only failures (full logs: backend/_build/check.log, backend/_build/web-check.log)
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

# One worktree per branch, with its own database files (in its own backend/data/)
# and port pair, so several checkouts can run at once. PORT in the worktree's
# .env picks the API port (web: PORT+1); KNOWSEEK_WORKSPACE names its image and
# database in the compose app container.
# Runs from any checkout. The branch starts at BASE (default origin/main).
worktree: ## Create a worktree + branch + databases + port pair: make worktree NAME=my-branch
	@[[ "$(NAME)" =~ ^[a-z0-9][a-z0-9-]{0,30}$$ ]] || { echo "Usage: make worktree NAME=<lowercase-letters-digits-dashes, max 31 chars>"; exit 1; }
	git fetch origin main
	git worktree add -b "$(NAME)" "$(WORKTREES)/$(NAME)" "$(BASE)"
	@if [ -f "$(MAIN_REPO)/.env" ]; then grep -vE '^[[:space:]]*(export[[:space:]]+)?(KNOWSEEK_WORKSPACE|PORT)=' "$(MAIN_REPO)/.env" > "$(WORKTREES)/$(NAME)/.env" || true; fi
	@echo "KNOWSEEK_WORKSPACE=$(NAME)" >> "$(WORKTREES)/$(NAME)/.env"
	@# Worktrees do not need Ollama (tests pin hashing). Opt in by editing .env. ADR 0016.
	@grep -qE '^[[:space:]]*(export[[:space:]]+)?EMBEDDINGS_ADAPTER=' "$(WORKTREES)/$(NAME)/.env" || echo "EMBEDDINGS_ADAPTER=hashing" >> "$(WORKTREES)/$(NAME)/.env"
	@# First port pair in 4100, 4200, ... 4900 that no other worktree's .env uses and nothing listens on.
	@port=""; for n in 4100 4200 4300 4400 4500 4600 4700 4800 4900; do \
		if grep -qsxE "[[:space:]]*(export[[:space:]]+)?PORT=$$n[[:space:]]*" "$(WORKTREES)"/*/.env; then continue; fi; \
		if lsof -nP -iTCP:$$n -iTCP:$$((n + 1)) -sTCP:LISTEN >/dev/null 2>&1; then continue; fi; \
		port=$$n; break; \
	done; \
	[ -n "$$port" ] || { echo "No free port pair in 4100..4900. Remove a worktree or set PORT in $(WORKTREES)/$(NAME)/.env"; exit 1; }; \
	echo "PORT=$$port" >> "$(WORKTREES)/$(NAME)/.env"
	@$(MAKE) -C "$(WORKTREES)/$(NAME)" setup || { echo "Setup failed. The worktree exists: fix the problem, then run 'make setup' inside $(WORKTREES)/$(NAME)"; exit 1; }
	@port="$$(sed -n 's/^PORT=//p' "$(WORKTREES)/$(NAME)/.env" | tail -n 1)"; \
	echo "Worktree ready: $(WORKTREES)/$(NAME)"; \
	echo "  databases: backend/data/knowseek_dev.db, backend/data/knowseek_test.db"; \
	echo "  ports:     API $$port (make dev), web UI $$((port + 1)) (make web)"

worktree-rm: ## Remove a worktree and its database files (keeps the branch): make worktree-rm NAME=...
	@test -d "$(WORKTREES)/$(NAME)" || { echo "No worktree at $(WORKTREES)/$(NAME)"; exit 1; }
	git worktree remove --force "$(WORKTREES)/$(NAME)"
