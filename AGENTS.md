# Agent guide

Read this file before you change anything. Then read `docs/ARCHITECTURE.md`.
For Elixir and Phoenix coding rules, read `backend/AGENTS.md`.

## What this project is

Knowseek takes a query, searches its own index, and returns relevant data. When the index does not cover the query, it seeks new data from external sources and indexes it. See `README.md`.

## Repository layout

```
backend/              Elixir/Phoenix API (owns the database schema)
  data/               this checkout's SQLite databases (git-ignored)
  lib/knowseek/       domain code (contexts)
  lib/knowseek_web/   HTTP layer (JSON controllers only)
  priv/repo/migrations/
  test/
frontend/            web UI: Vite + React + TypeScript (talks to the backend over HTTP only)
docs/
  ARCHITECTURE.md     components, data flow, data model
  decisions/          ADRs: one file per significant decision
  notes/              research findings
docker-compose.yml    the `app` profile runs the release image (backend/Dockerfile); development needs no Docker
Makefile              all common commands
```

## Commands

Run everything from the repository root.

| Command | What it does |
| --- | --- |
| `make setup` | Fetch deps and the pinned sqlite-vec extension, create and migrate the dev and test databases (SQLite files in `backend/data/`) |
| `make start` | Run the API and the web UI together in one terminal (Ctrl-C stops both). |
| `make dev` | Run the API on `$PORT` (the environment, then `.env`, then 4000). Checks Ollama first (`make ollama`). |
| `make web` | Run the web UI on `$PORT` + 1. It proxies `/api` to the API. |
| `make test` | Run the backend test suite. Pass `ARGS=test/knowseek/search_test.exs` for one file. |
| `make worktree NAME=...` | Create a worktree + branch (from `origin/main`) next to the main checkout, copy `.env`, add `KNOWSEEK_WORKSPACE`, `EMBEDDINGS_ADAPTER=hashing` (unless set) and a free `PORT` (4100, 4200, ...), and set it up (its own database files). Prints the path, database files and ports. |
| `make worktree-rm NAME=...` | Remove the worktree, and with it its database files (keeps the branch). |
| `make db-reset` | Delete and recreate the dev database, with the seeds. |
| `make ollama` | Run `scripts/ensure-ollama`: check that a native Ollama runs and pull `bge-m3` (about 1.2 GB). Does nothing when `EMBEDDINGS_ADAPTER` is not `ollama`. `setup`, `dev`, `iex`, and `start` run it. `make test` and `make check` do not. |
| `make check-migrations` | Check migration file names: unique versions, the generator's format, none in the future. `make check` and `make check-quiet` run it first. |
| `make check-docs` | Check ADR numbers, README index rows, and relative markdown links. `make check` and `make check-quiet` run it. |
| `make check-shell` | ShellCheck on `scripts/` (skipped with a note if `shellcheck` is not installed). `make check` and `make check-quiet` run it. |
| `make check-migration-roundtrip` | Roll back and re-apply the migrations your branch adds, on an empty database and on one with data from `origin/main` (a temporary SQLite file). Slow, so not part of `make check`; run it when you add a migration. |
| `make check-security` | `scripts/check-security`: `mix hex.audit`, `mix deps.audit`, `mix sobelow`, `npm audit`; runs all four and fails if any fails (needs the network). CI and the daily audit run it; not part of `make check`. |
| `make check-secrets` | gitleaks over the whole git history (needs Docker). CI runs it; not part of `make check`. |
| `make check` | Backend: compile with warnings as errors, format, Credo, tests. Frontend: types, format, tests. **Must pass before you finish.** |
| `make check-quiet` | Same as `make check`, but prints only a summary or the failures. |

The Makefile loads `.env` (see `.env.example`), so run single test files with `make test ARGS=...`, not with a bare `mix test`.

**Databases.** SQLite, one file per checkout: `backend/data/knowseek_dev.db` and `backend/data/knowseek_test.db` (git-ignored; `DATABASE_PATH` replaces the path, for dev and test alike). Every connection loads sqlite-vec v0.1.9, which `mix sqlite_vec.fetch` downloads into `backend/priv/sqlite_vec/` and checks against a pinned SHA-256 (`setup`, `test` and `ecto.migrate` run it first; it needs the network once). Nothing runs in Docker for development, tests or CI. See `docs/decisions/0030-sqlite-single-datastore.md`.

**Parallel checkouts.** `make worktree NAME=...` creates one worktree per branch at `../knowseek-worktrees/<name>`. It has its own database files (its own `backend/data/`), and its `.env` sets `PORT` (its own port pair: API on `PORT`, web UI on `PORT`+1) and `KNOWSEEK_WORKSPACE` (its image and database file in the compose `app` container), so several checkouts run at once without colliding. `make worktree-rm NAME=...` removes it, database files included. The main checkout uses port 4000.

New migration: `cd backend && mix ecto.gen.migration name_with_underscores`. Never write the version by hand. Two branches that generate a migration in the same second get the same version, and each passes CI alone. After `git fetch origin && git rebase origin/main`, run `make check-quiet`. If `check-migrations` reports a duplicate, delete your new file and generate it again.

A migration needs a working `down` (or a reversible `change`): CI rolls it back and applies it again. If it cannot be undone on purpose, make the first line of the file `# irreversible: <reason>`. See `docs/decisions/0020-ci-hardening.md`.

The default embedding adapter is Ollama (`brew install ollama`, `brew services start ollama`): one server on `localhost:11434` (ADR 0016). Tests never use it (they pin the hashing adapter). To run without it, set `EMBEDDINGS_ADAPTER=hashing` in `.env`. After you switch adapters on a database, run `make db-reset`.

## Architecture rules

These keep the code base coherent. If a task needs you to break one, write an ADR first.

1. **Context boundaries.** Code outside a context calls only the context's public module (`Knowseek.Documents`, `Knowseek.Search`, `Knowseek.Discovery`, `Knowseek.Lookup`, `Knowseek.Entities`, `Knowseek.Cards`, `Knowseek.Activity`). Do not query another context's schemas directly, except for read joins inside `Knowseek.Search`.
2. **One write path into the index.** Only `Knowseek.Documents.ingest/1` writes documents and chunks.
3. **Sources only find data.** A `Knowseek.Discovery.Source` returns candidates. It never writes to the database.
4. **Pluggable parts are behaviours plus config.** Embedding providers, discovery sources, entity resolvers, and card providers implement a behaviour and are selected in `config/*.exs`. Add new providers the same way.
5. **No external calls inside a transaction.** Call APIs first, then write.
6. **Slow or external work runs in Oban jobs**, not in the request path, and the request path may only enqueue. One existing exception: `Search` embeds the query through the embeddings adapter in the request path (503 on provider failure, ADR 0016). Live-fact card and entity-cache refreshes run in supervised in-process tasks instead of Oban: `Knowseek.Cache` is that mechanism, and `Knowseek.Entities` (task 030) and `Knowseek.Cards` (task 031) are built on it. The card endpoint (`GET /api/cards`) reads only caches and never calls a provider or Wikidata, and refreshes are disposable (their retry is the next poll). A cache whose keys come from user input sets `max_in_flight` and `reserve_for_refresh` (the entity cache does; ADR 0023), and the endpoints that take anonymous input are rate-limited per client (`KnowseekWeb.Plugs.RateLimit`). Everything that writes to the index still goes through Oban. The search log is written by `Knowseek.Activity.Recorder`, a supervised in-process writer: the request path only sends it a message (ADR 0031). See `docs/decisions/0017-live-fact-cards.md`.
7. **The embedding size is fixed by the schema.** `chunk_vectors.embedding` is `float[1024]` (sqlite-vec). A model with another size needs a migration and a re-embed plan (see `docs/decisions/0004-embeddings.md`).
8. **The backend owns the schema.** Services in `services/` talk to the backend through HTTP or jobs, not through its tables.
9. **The frontend uses only the public JSON API.** `frontend/src/types.ts` mirrors the `*JSON` views. If you change a response shape, change the types in the same branch.

## Testing rules

- Frontend tests (`cd frontend && npm test`) stub `fetch` (see `frontend/test/fixtures.ts`). They never call the backend.
- Tests never call the network. Stub HTTP with `Req.Test` (pass `plug: {Req.Test, Name}` through config) and use fake sources and adapters from `test/support/`.
- A `Req.Test` stub that a supervised task calls (the `Knowseek.Cache` fetch behind `Knowseek.Entities` and `Knowseek.Cards`) needs shared mode: a non-async test with `setup :set_req_test_from_context` (see `test/knowseek/entities_test.exs` and `test/knowseek/cards_test.exs`). Wait for the fetch with `Knowseek.Entities.await/2` or `Knowseek.Cards.await/2`, never with a sleep.
- Oban runs in `:manual` testing mode. Assert with `assert_enqueued/1`, and run jobs with `perform_job/2`.
- Use the fixtures in `test/support/fixtures.ex`. Add new fixtures there.
- Every new public function gets a test. Every bug fix gets a regression test.
- Tests that use the database are not async (`use Knowseek.DataCase, async: false`; the same for `KnowseekWeb.ConnCase`). SQLite has one writer, and the SQL sandbox holds a transaction with the write lock for the whole test (every transaction starts IMMEDIATE, ADR 0030), so two sandbox owners at once would wait on each other. `DataCase` therefore gives an async test no connection: a database call there fails with an ownership error. Tests that touch no `Repo`, `Documents`, `Search` or Oban assertion stay async.
- Tests read the vectors exactly: sqlite-vec has no approximate index, so no test depends on index state. Read a stored vector with `chunk_embedding/1` from `test/support/fixtures.ex`.

## How work flows

Work is tracked in GitHub Issues. Decisions live in `docs/decisions/` (ADRs), research findings in `docs/notes/`.

### Kinds of work

Every issue has one kind label:

|Kind|Examples|Path|
|---|---|---|
|`maintenance`|dependency bumps, security advisories|CI green, owner looks it over, merge. No issue needed: the Dependabot PR or audit issue is the record.|
|`internal`|refactor, bug fix, tooling|plan, owner approves, implement, PR, merge. If it touches the UI, owner QA on a local preview before merge.|
|`feature`|anything a user would notice|pitch, design with the owner (as many rounds as it takes), plan, owner approves, implement, owner QA on a local preview, merge|
|`research`|comparing models, spikes|question, findings in `docs/notes/`, owner reads. Nothing merges into the app.|

### The plan gate

Nothing is implemented before the owner approves a plan, except `maintenance`. A plan is short: what changes, what does not, how it is verified, and the risks. The owner approves it in chat. Then the agent posts the approved plan as a comment on the issue and adds the `plan-approved` label. Implementation does not start without that label.

If the work turns out bigger or different than the plan, stop and bring back a revised plan. Do not widen scope silently.

### Writing issues

- Title, kind label, then the pitch: what the owner gets from it, in one to three sentences. Lead with the point.
- Then open questions, if any.
- No implementation detail until the plan stage. Put research in `docs/notes/` and link to it.

### Status

Status comes from GitHub, not from text in files:

- open issue: backlog
- `plan-approved`: planned
- open PR with `Closes #N`: in progress or in review
- closed: done (merging the PR closes the issue)

### Pull requests

Work on a branch, never on `main`. Run `make check-quiet`; it must pass. Open a PR against `main` with `Closes #N` and fill in the template. CI must be green. The owner reviews and merges. Never push to `main`.

### QA for features and UI changes

There is no hosted preview. Run the branch in its own worktree (`make worktree NAME=...` gives it its own databases and ports), start it with `make start`, and give the owner the URL.

### CI

`.github/workflows/ci.yml` runs on every pull request and on pushes to `main`, in eight jobs: `backend` (compile with warnings as errors, format, Credo, unused dependencies, sqlite-vec fetched and loaded through exqlite (it prints `vec_version()`), tests on a SQLite file; no service container), `frontend` (types, format, tests, build), `image` (builds `backend/Dockerfile` without pushing it), `migrations` (the added migrations roll back and apply again, on an empty database and on one with data from `origin/main`, on a temporary SQLite file), `docs` (`scripts/check-docs`), `shellcheck` (`scripts/`), `security` (`mix hex.audit`, `mix deps.audit`, `mix sobelow`, `npm audit`), and `secrets` (gitleaks over the whole history). Seven are required by the GitHub ruleset on `main`: `backend`, `frontend`, `image`, `migrations`, `docs`, `shellcheck`, and `secrets`. `security` is not required, on purpose: a newly published advisory must not block unrelated pull requests. A scheduled workflow (`.github/workflows/security-audit.yml`, daily) runs `make check-security` on `main` and keeps one GitHub issue labelled `security-audit` open while the audit fails. Dependabot (`.github/dependabot.yml`) opens update PRs: daily for `mix` and `npm`, weekly for the rest; it does not see sqlite-vec (bump `mix sqlite_vec.fetch` by hand). Failure policy: `docs/decisions/0020-ci-hardening.md`.

## Definition of done

- `make check` (or `make check-quiet`) passes.
- New behaviour has tests. Tests do not use the network.
- Docs and the issue are up to date.
- No secrets in the repository. Read API keys from environment variables in `config/runtime.exs`, and list them in `.env.example`.
