# Entry points for humans, agents, and CI. Run `make help` for the list.

SHELL := /bin/bash
PORT ?= $(or $(CONDUCTOR_PORT),4000)

.PHONY: help setup db-up db-down db-reset dev iex test check fmt

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

setup: db-up ## Install deps and create + migrate the dev and test databases
	@command -v mise >/dev/null && mise install || true
	cd backend && mix deps.get && mix ecto.setup
	cd backend && MIX_ENV=test mix do ecto.create --quiet + ecto.migrate --quiet

db-up: ## Start Postgres (pgvector) in Docker
	docker compose up -d --wait db

db-down: ## Stop Postgres (data is kept in a Docker volume)
	docker compose down

db-reset: db-up ## Drop and recreate this workspace's dev database
	cd backend && mix ecto.reset

dev: db-up ## Run the API server on $PORT (defaults to $CONDUCTOR_PORT, then 4000)
	cd backend && mix do ecto.create --quiet + ecto.migrate --quiet
	cd backend && PORT=$(PORT) mix phx.server

iex: db-up ## Run the API server inside an IEx shell
	cd backend && PORT=$(PORT) iex -S mix phx.server

test: db-up ## Run the test suite
	cd backend && mix test

check: db-up ## Compile with warnings as errors, format, credo, test. Run before you finish a task.
	cd backend && mix precommit

fmt: ## Format Elixir code
	cd backend && mix format
