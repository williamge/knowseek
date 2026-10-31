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
services/             future non-Elixir background services (see services/README.md)
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
| `make start` | Run the API and the web UI together in one terminal (Ctrl-C stops both). For the owner; agents use `make dev` and `make web`. |
| `make dev` | Run the API on `$CONDUCTOR_PORT` (or 4000). Checks Ollama first (`make ollama`). |
| `make web` | Run the web UI on `$CONDUCTOR_PORT` + 1. It proxies `/api` to the API. |
| `make test` | Run the backend test suite. Pass `ARGS=test/knowseek/search_test.exs` for one file. |
| `make worktree NAME=...` | Create a worktree + branch for a task, copy `.env`, and set up its own databases. If `.env` does not set `EMBEDDINGS_ADAPTER`, the worktree gets `EMBEDDINGS_ADAPTER=hashing`, so setup and tests do not need Ollama; edit its `.env` to use Ollama. If setup fails, fix the cause and run `make setup` inside the worktree. See "How to work on a task". |
| `make worktree-rm NAME=...` | Drop a worktree's databases and remove the worktree. |
| `make ollama` | Run `scripts/ensure-ollama`: check that a native Ollama runs and pull `bge-m3` (about 1.2 GB). Does nothing when `EMBEDDINGS_ADAPTER` is not `ollama`. `setup`, `dev`, `iex`, and `start` run it. `make test` and `make check` do not. |
| `make guard-main` | Fail if the main checkout has uncommitted changes (you edited it by mistake). Set `ALLOW_DIRTY_MAIN=1` to skip when the owner has local edits there. |
| `make check-migrations` | Check migration file names: unique versions, the generator's format, none in the future. `make check` and `make check-quiet` run it first. |
| `make check` | Backend: compile with warnings as errors, format, Credo, tests. Frontend: types, format, tests. **Must pass before you finish.** |
| `make check-quiet` | Same as `make check`, but prints only a summary or the failures. Agents use this one. |

Run single test files with `make test ARGS=...`, not with a bare `mix test`. The Makefile loads `.env`, which holds `KNOWSEEK_WORKSPACE`. A bare `mix test` in a worktree would use the shared `knowseek_test` database.

To save tokens:

- While you work, run only the test files that you change (add `--failed` to re-run only failures).
- Run `make check-quiet` one time at the end, not after each edit.
- Do not read whole large files when a `grep` or a line range answers the question.

New migration: `cd backend && mix ecto.gen.migration name_with_underscores`. Never write the version by hand. Two branches that generate a migration in the same second get the same version, and each passes CI alone. After `git fetch origin && git rebase origin/main`, run `make check-quiet`. If `check-migrations` reports a duplicate, delete your new file and generate it again.

### Databases and parallel workspaces

One Postgres container (`docker compose`, project name `knowseek`) serves every workspace. A workspace is a git worktree (see below) or a Conductor workspace. Each one gets its own databases, named from `KNOWSEEK_WORKSPACE`, or `CONDUCTOR_WORKSPACE_NAME` if that is not set (for example `knowseek_dev_task_014_one_hit`). `make worktree` writes `KNOWSEEK_WORKSPACE` into the worktree's `.env`. You can run tests and servers in many workspaces at once. If a database is missing, run `make setup` again. In the main checkout, with neither variable set, commands use the shared `knowseek_dev` and `knowseek_test` databases. Do not work on a task there.

The default embedding adapter is Ollama (`brew install ollama`, `brew services start ollama`), shared the same way: one server on `localhost:11434` for every local workspace (ADR 0016). Tests never use it (they pin the hashing adapter). Remote workspaces cannot reach it; set `EMBEDDINGS_ADAPTER=hashing` there. After you switch adapters on a database, run `make db-reset`.

## Architecture rules

These keep the code base coherent while many agents work in parallel. If a task needs you to break one, write an ADR first.

1. **Context boundaries.** Code outside a context calls only the context's public module (`Knowseek.Documents`, `Knowseek.Search`, `Knowseek.Discovery`, `Knowseek.Lookup`, `Knowseek.Entities`). Do not query another context's schemas directly, except for read joins inside `Knowseek.Search`.
2. **One write path into the index.** Only `Knowseek.Documents.ingest/1` writes documents and chunks.
3. **Sources only find data.** A `Knowseek.Discovery.Source` returns candidates. It never writes to the database.
4. **Pluggable parts are behaviours plus config.** Embedding providers, discovery sources, and entity resolvers implement a behaviour and are selected in `config/*.exs`. Add new providers the same way.
5. **No external calls inside a transaction.** Call APIs first, then write.
6. **Slow or external work runs in Oban jobs**, not in the request path, and the request path may only enqueue. One existing exception: `Search` embeds the query through the embeddings adapter in the request path (503 on provider failure, ADR 0016). Live-fact card and entity-cache refreshes run in supervised in-process tasks instead of Oban: `Knowseek.Cache` is that mechanism, and `Knowseek.Entities` (task 030) is built on it. The card endpoint (tasks 031-034, not built yet) reads only a cache and never calls a provider, and refreshes are disposable (their retry is the next poll). Everything that writes to the index still goes through Oban. See `docs/decisions/0017-live-fact-cards.md`.
7. **The embedding size is fixed by the schema.** `chunks.embedding` is `vector(1024)`. A model with another size needs a migration and a re-embed plan (see `docs/decisions/0004-embeddings.md`).
8. **The backend owns the schema.** Services in `services/` talk to the backend through HTTP or jobs, not through its tables.
9. **The frontend uses only the public JSON API.** `frontend/src/types.ts` mirrors the `*JSON` views. If you change a response shape, change the types in the same branch.

## Testing rules

- Frontend tests (`cd frontend && npm test`) stub `fetch` (see `frontend/test/fixtures.ts`). They never call the backend.
- Tests never call the network. Stub HTTP with `Req.Test` (pass `plug: {Req.Test, Name}` through config) and use fake sources and adapters from `test/support/`.
- A `Req.Test` stub that a supervised task calls (the `Knowseek.Cache` fetch behind `Knowseek.Entities`) needs shared mode: a non-async test with `setup :set_req_test_from_context` (see `test/knowseek/entities_test.exs`). Wait for the fetch with `Knowseek.Entities.await/2`, never with a sleep.
- Oban runs in `:manual` testing mode. Assert with `assert_enqueued/1`, and run jobs with `perform_job/2`.
- Use the fixtures in `test/support/fixtures.ex`. Add new fixtures there.
- Every new public function gets a test. Every bug fix gets a regression test.
- Search tests that load many chunks (the 35-chunk documents in `test/knowseek/search_test.exs`) can bloat the HNSW index in a long-lived local test database. Unrelated search tests then fail on and off. Run `VACUUM FULL chunks; REINDEX TABLE chunks` against that database (`psql` into `knowseek_test_<workspace>`), or drop and recreate it with `make setup`. CI uses a fresh database and is not affected.

## How to work on a task

Every task is one worktree, one branch, and one pull request. **Never commit to or push `main`.** Never merge a pull request. A human merges.

1. Pick a task in `docs/tasks/` (or take the one you were given). Read the whole task file.
2. Create a worktree from the main checkout: `make worktree NAME=task-014-one-hit` (lowercase letters, digits, and dashes; at most 31 characters). It branches from `origin/main`. Work only inside `../knowseek-worktrees/<name>`. Do not edit the main checkout. The read/edit/write/grep/glob tools resolve relative paths against the main checkout, not against `cd` in bash, so every file path MUST be absolute under the worktree. Run `make guard-main` (one line when clean) before the first commit and before opening the PR; `make check-quiet` runs it too.
   - Agent safety: NEVER kill processes by name or pattern (no `pkill`, `killall`, or `pgrep`-then-kill by name): a pattern like `phx.server` kills the owner's dev server. Kill only PIDs you started and recorded, after checking their cwd is under your worktree (`lsof -p <pid> | grep cwd`). Use only your assigned `CONDUCTOR_PORT` pair; never ports 4000/4001.
   - `make check` / `make check-quiet` run `db-up`, which applies compose changes. If your task changes `docker-compose.yml`, running them recreates the SHARED Postgres container `knowseek-db-1` (same volume, brief downtime for the owner's API). Verify compose changes with `docker compose config`, tell the parent in your report, and never run `docker compose down`.
3. Keep the change small enough to review.
4. If you make a decision that a later agent needs to know about (new dependency, new service, schema change, changed contract), add an ADR in `docs/decisions/` with the next free number.
5. Update the docs that your change makes wrong: `README.md` (API table), `docs/ARCHITECTURE.md`, this file.
6. In the task file, set `Status: done` and add a short "Outcome" section: what you built, what you left out, and follow-up tasks. Add new task files for follow-ups.
7. Run `make check-quiet`. It must pass.
8. Commit, push the branch (`git push -u origin <name>`), and open a pull request against `main` with `gh pr create`. Fill in the pull request template. Link the task file.
9. Watch CI with `gh pr checks --watch`. If a check fails, fix it in the same branch and push again. Do not stop at a red PR.
10. Report the PR URL. Leave the worktree in place until the PR is merged. After the merge, `make worktree-rm NAME=...` cleans up.

### CI

`.github/workflows/ci.yml` runs on every pull request and on pushes to `main`. The `backend` job compiles with warnings as errors, checks formatting, runs Credo, checks for unused dependencies, and runs the tests against Postgres + pgvector. The `frontend` job runs the type check, the format check, the tests, and the build. The `image` job builds `backend/Dockerfile` without pushing it. This is the same as `make check`, plus the build. A PR must be green before it is merged. The `backend`, `frontend`, and `image` jobs are the required checks. The repository is public, and the GitHub ruleset "main protection" enforces this: a pull request is required (0 approvals), the three checks must pass, and `main` cannot be deleted or force-pushed (no bypass actors; merged branches are deleted). A human merges; agents never merge and never push to `main`. See `docs/decisions/0010-worktrees-and-pull-requests.md`.

### Coordinating several agents

To run several tasks at once (one subagent each), read `docs/WORKING-WITH-AGENTS.md`. It has the steps, the rules that kept parallel work from colliding, and `docs/agent-brief.md`, the prompt templates to copy.

## Definition of done

- `make check` (or `make check-quiet`) passes.
- New behaviour has tests. Tests do not use the network.
- Docs and the task file are up to date.
- No secrets in the repository. Read API keys from environment variables in `config/runtime.exs`, and list them in `.env.example`.
- A pull request is open against `main`, and its CI run is green. Nothing is pushed to `main`.
