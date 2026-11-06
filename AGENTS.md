# Agent guide

Read this file before you change anything. Then read `docs/ARCHITECTURE.md`.
For Elixir and Phoenix coding rules, read `backend/AGENTS.md`.

## What this project is

Knowseek takes a query, searches its own index, and returns relevant data. When the index does not cover the query, it seeks new data from external sources and indexes it. See `README.md`.

## Repository layout

```
backend/              Elixir/Phoenix API (owns the database schema)
  lib/knowseek/       domain code (contexts)
  lib/knowseek_web/   HTTP layer (JSON controllers only)
  priv/repo/migrations/
  test/
frontend/            web UI: Vite + React + TypeScript (talks to the backend over HTTP only)
docs/
  ARCHITECTURE.md     components, data flow, data model
  decisions/          ADRs: one file per significant decision
  tasks/              backlog: one file per task
docker-compose.yml    Postgres + pgvector; `app` profile runs the release image (backend/Dockerfile)
Makefile              all common commands
```

## Commands

Run everything from the repository root.

| Command | What it does |
| --- | --- |
| `make setup` | Start Postgres, fetch deps, create and migrate dev + test databases |
| `make start` | Run the API and the web UI together in one terminal (Ctrl-C stops both). |
| `make dev` | Run the API on `$PORT` (default 4000). Checks Ollama first (`make ollama`). |
| `make web` | Run the web UI on `$PORT` + 1. It proxies `/api` to the API. |
| `make test` | Run the backend test suite. Pass `ARGS=test/knowseek/search_test.exs` for one file. |
| `make ollama` | Run `scripts/ensure-ollama`: check that a native Ollama runs and pull `bge-m3` (about 1.2 GB). Does nothing when `EMBEDDINGS_ADAPTER` is not `ollama`. `setup`, `dev`, `iex`, and `start` run it. `make test` and `make check` do not. |
| `make check-migrations` | Check migration file names: unique versions, the generator's format, none in the future. `make check` and `make check-quiet` run it first. |
| `make check-docs` | Check task and ADR numbers, README index rows, `Status:` and `Depends on:` lines, and relative markdown links. `make check` and `make check-quiet` run it. |
| `make check-shell` | ShellCheck on `scripts/` (skipped with a note if `shellcheck` is not installed). `make check` and `make check-quiet` run it. |
| `make check-migration-roundtrip` | Roll back and re-apply the migrations your branch adds, on an empty database and on one with data from `origin/main`. Slow, so not part of `make check`; run it when you add a migration. |
| `make check-security` | `scripts/check-security`: `mix hex.audit`, `mix deps.audit`, `mix sobelow`, `npm audit`; runs all four and fails if any fails (needs the network). CI and the daily audit run it; not part of `make check`. |
| `make check-secrets` | gitleaks over the whole git history (needs Docker). CI runs it; not part of `make check`. |
| `make check` | Backend: compile with warnings as errors, format, Credo, tests. Frontend: types, format, tests. **Must pass before you finish.** |
| `make check-quiet` | Same as `make check`, but prints only a summary or the failures. |

The Makefile loads `.env` (see `.env.example`), so run single test files with `make test ARGS=...`, not with a bare `mix test`. One Postgres container (`docker compose`, project name `knowseek`) holds the databases `knowseek_dev` and `knowseek_test`.

New migration: `cd backend && mix ecto.gen.migration name_with_underscores`. Never write the version by hand. Two branches that generate a migration in the same second get the same version, and each passes CI alone. After `git fetch origin && git rebase origin/main`, run `make check-quiet`. If `check-migrations` reports a duplicate, delete your new file and generate it again.

A migration needs a working `down` (or a reversible `change`): CI rolls it back and applies it again. If it cannot be undone on purpose, make the first line of the file `# irreversible: <reason>`. See `docs/decisions/0020-ci-hardening.md`.

The default embedding adapter is Ollama (`brew install ollama`, `brew services start ollama`): one server on `localhost:11434` (ADR 0016). Tests never use it (they pin the hashing adapter). To run without it, set `EMBEDDINGS_ADAPTER=hashing` in `.env`. After you switch adapters on a database, run `make db-reset`.

## Architecture rules

These keep the code base coherent. If a task needs you to break one, write an ADR first.

1. **Context boundaries.** Code outside a context calls only the context's public module (`Knowseek.Documents`, `Knowseek.Search`, `Knowseek.Discovery`, `Knowseek.Lookup`, `Knowseek.Entities`, `Knowseek.Cards`). Do not query another context's schemas directly, except for read joins inside `Knowseek.Search`.
2. **One write path into the index.** Only `Knowseek.Documents.ingest/1` writes documents and chunks.
3. **Sources only find data.** A `Knowseek.Discovery.Source` returns candidates. It never writes to the database.
4. **Pluggable parts are behaviours plus config.** Embedding providers, discovery sources, entity resolvers, and card providers implement a behaviour and are selected in `config/*.exs`. Add new providers the same way.
5. **No external calls inside a transaction.** Call APIs first, then write.
6. **Slow or external work runs in Oban jobs**, not in the request path, and the request path may only enqueue. One existing exception: `Search` embeds the query through the embeddings adapter in the request path (503 on provider failure, ADR 0016). Live-fact card and entity-cache refreshes run in supervised in-process tasks instead of Oban: `Knowseek.Cache` is that mechanism, and `Knowseek.Entities` (task 030) and `Knowseek.Cards` (task 031) are built on it. The card endpoint (`GET /api/cards`) reads only caches and never calls a provider or Wikidata, and refreshes are disposable (their retry is the next poll). A cache whose keys come from user input sets `max_in_flight` and `reserve_for_refresh` (the entity cache does; ADR 0023), and the endpoints that take anonymous input are rate-limited per client (`KnowseekWeb.Plugs.RateLimit`). Everything that writes to the index still goes through Oban. See `docs/decisions/0017-live-fact-cards.md`.
7. **The embedding size is fixed by the schema.** `chunks.embedding` is `vector(1024)`. A model with another size needs a migration and a re-embed plan (see `docs/decisions/0004-embeddings.md`).
8. **The backend owns the schema.** Services in `services/` talk to the backend through HTTP or jobs, not through its tables.
9. **The frontend uses only the public JSON API.** `frontend/src/types.ts` mirrors the `*JSON` views. If you change a response shape, change the types in the same branch.

## Testing rules

- Frontend tests (`cd frontend && npm test`) stub `fetch` (see `frontend/test/fixtures.ts`). They never call the backend.
- Tests never call the network. Stub HTTP with `Req.Test` (pass `plug: {Req.Test, Name}` through config) and use fake sources and adapters from `test/support/`.
- A `Req.Test` stub that a supervised task calls (the `Knowseek.Cache` fetch behind `Knowseek.Entities` and `Knowseek.Cards`) needs shared mode: a non-async test with `setup :set_req_test_from_context` (see `test/knowseek/entities_test.exs` and `test/knowseek/cards_test.exs`). Wait for the fetch with `Knowseek.Entities.await/2` or `Knowseek.Cards.await/2`, never with a sleep.
- Oban runs in `:manual` testing mode. Assert with `assert_enqueued/1`, and run jobs with `perform_job/2`.
- Use the fixtures in `test/support/fixtures.ex`. Add new fixtures there.
- Every new public function gets a test. Every bug fix gets a regression test.
- Tests read the vectors exactly. `config/test.exs` turns index scans off for the test database (`enable_indexscan: "off"`), so the vector query in `Knowseek.Search` is a sequential scan and sort, not an approximate HNSW scan. Reason: every test rolls back its inserts, but the chunks stay in the HNSW index as dead entries until a vacuum, and they bloat the table, so the planner picks the HNSW scan even when one row is live. A graph full of look-alike dead vectors (the 35-chunk documents, the repeated fixture texts) often has no path to a new, different vector and returns no row. Search tests then fail at random, on a fresh CI database too, once enough earlier tests have run. Do not turn index scans back on in tests, and do not write a test that needs the HNSW scan to find a row. `with_ef_search/2` is tested by reading the settings.
- One sanctioned exception: `test/knowseek/search_hnsw_test.exs` (tag `:hnsw_guard`; `mix test --only hnsw_guard`) is the guard for the HNSW scan (task 044, ADR 0024). It runs the real index scan against committed rows, so it isolates itself: its own connection pool (a dynamic `Knowseek.Repo` outside the SQL sandbox, with `enable_indexscan = on` and `enable_seqscan = off` for that pool only, so no other test sees them), `async: false` (ExUnit runs it alone, after every async module), a `TRUNCATE chunks, documents` before it starts (a fresh index, without the dead entries that rolled-back tests leave) and in `on_exit`, and autovacuum switched off for `chunks` meanwhile (a vacuum would remove the dead entries it needs) and restored in `on_exit` (the restore runs first, and both steps run even if one fails). It commits through `Documents.ingest/1` and checks that the plan uses `chunks_embedding_vector_cosine_ops_index`. Do not copy this pattern into other tests: a test that needs a real index scan belongs in that module. After a guard run that was killed (Ctrl-C, a CI timeout), run it again, or run `TRUNCATE chunks, documents CASCADE` and `ALTER TABLE chunks RESET (autovacuum_enabled)` in your test database: its committed rows would break other tests' counts.

## How changes land

Work on a branch, never on `main`. Run `make check-quiet`; it must pass. Push the branch and open a pull request against `main` (fill in `.github/pull_request_template.md`). CI must be green. The owner reviews and merges. Never push to `main`.

### CI

`.github/workflows/ci.yml` runs on every pull request and on pushes to `main`, in eight jobs: `backend` (compile with warnings as errors, format, Credo, unused dependencies, tests against Postgres + pgvector), `frontend` (types, format, tests, build), `image` (builds `backend/Dockerfile` without pushing it), `migrations` (the added migrations roll back and apply again, on an empty database and on one with data from `origin/main`), `docs` (`scripts/check-docs`), `shellcheck` (`scripts/`), `security` (`mix hex.audit`, `mix deps.audit`, `mix sobelow`, `npm audit`), and `secrets` (gitleaks over the whole history). Seven are required by the GitHub ruleset on `main`: `backend`, `frontend`, `image`, `migrations`, `docs`, `shellcheck`, and `secrets`. `security` is not required, on purpose: a newly published advisory must not block unrelated pull requests. A scheduled workflow (`.github/workflows/security-audit.yml`, daily) runs `make check-security` on `main` and keeps one GitHub issue labelled `security-audit` open while the audit fails. Dependabot (`.github/dependabot.yml`) opens update PRs: daily for `mix` and `npm`, weekly for the rest. Failure policy: `docs/decisions/0020-ci-hardening.md`.

## Definition of done

- `make check` (or `make check-quiet`) passes.
- New behaviour has tests. Tests do not use the network.
- Docs and the task file are up to date.
- No secrets in the repository. Read API keys from environment variables in `config/runtime.exs`, and list them in `.env.example`.
