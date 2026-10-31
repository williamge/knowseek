# Agent guide

Read this file before you change anything. Then read `docs/ARCHITECTURE.md`.
For Elixir and Phoenix coding rules, read `backend/AGENTS.md`.

## What this project is

Knowseek takes a query, searches its own index, and returns relevant data. When the index does not cover the query, it seeks new data from external sources and indexes it. Users can also follow topics, which are refreshed on a schedule. See `README.md`.

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
docker-compose.yml    Postgres + pgvector
Makefile              all common commands
```

## Commands

Run everything from the repository root.

| Command | What it does |
| --- | --- |
| `make setup` | Start Postgres, fetch deps, create and migrate dev + test databases |
| `make dev` | Run the API on `$CONDUCTOR_PORT` (or 4000) |
| `make web` | Run the web UI on `$CONDUCTOR_PORT` + 1. It proxies `/api` to the API. |
| `make test` | Run the backend test suite. Pass `ARGS=test/knowseek/search_test.exs` for one file. |
| `make worktree NAME=...` | Create a worktree + branch for a task, copy `.env`, and set up its own databases. See "How to work on a task". |
| `make worktree-rm NAME=...` | Drop a worktree's databases and remove the worktree. |
| `make ollama` | Optional: check that a native Ollama runs and pull `bge-m3` (about 1.2 GB) for `EMBEDDINGS_ADAPTER=ollama` |
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

The optional Ollama server (`brew install ollama`, `brew services start ollama`) is shared the same way: one server on `localhost:11434` for every local workspace. Tests never use it. Remote workspaces cannot reach it.

## Architecture rules

These keep the code base coherent while many agents work in parallel. If a task needs you to break one, write an ADR first.

1. **Context boundaries.** Code outside a context calls only the context's public module (`Knowseek.Documents`, `Knowseek.Search`, `Knowseek.Discovery`, `Knowseek.Topics`, `Knowseek.Lookup`). Do not query another context's schemas directly, except for read joins inside `Knowseek.Search`.
2. **One write path into the index.** Only `Knowseek.Documents.ingest/1` writes documents and chunks.
3. **Sources only find data.** A `Knowseek.Discovery.Source` returns candidates. It never writes to the database.
4. **Pluggable parts are behaviours plus config.** Embedding providers and discovery sources implement a behaviour and are selected in `config/*.exs`. Add new providers the same way.
5. **No external calls inside a transaction.** Call APIs first, then write.
6. **Slow or external work runs in Oban jobs**, not in the request path. The request path may only enqueue.
7. **The embedding size is fixed by the schema.** `chunks.embedding` is `vector(1024)`. A model with another size needs a migration and a re-embed plan (see `docs/decisions/0004-embeddings.md`).
8. **The backend owns the schema.** Services in `services/` talk to the backend through HTTP or jobs, not through its tables.
9. **The frontend uses only the public JSON API.** `frontend/src/types.ts` mirrors the `*JSON` views. If you change a response shape, change the types in the same branch.

## Testing rules

- Frontend tests (`cd frontend && npm test`) stub `fetch` (see `frontend/test/fixtures.ts`). They never call the backend.
- Tests never call the network. Stub HTTP with `Req.Test` (pass `plug: {Req.Test, Name}` through config) and use fake sources and adapters from `test/support/`.
- Oban runs in `:manual` testing mode. Assert with `assert_enqueued/1`, and run jobs with `perform_job/2`.
- Use the fixtures in `test/support/fixtures.ex`. Add new fixtures there.
- Every new public function gets a test. Every bug fix gets a regression test.

## How to work on a task

Every task is one worktree, one branch, and one pull request. **Never commit to or push `main`.** Never merge a pull request. A human merges.

1. Pick a task in `docs/tasks/` (or take the one you were given). Read the whole task file.
2. Create a worktree from the main checkout: `make worktree NAME=task-014-one-hit` (lowercase letters, digits, and dashes; at most 31 characters). It branches from `origin/main`. Work only inside `../knowseek-worktrees/<name>`. Do not edit the main checkout.
3. Keep the change small enough to review.
4. If you make a decision that a later agent needs to know about (new dependency, new service, schema change, changed contract), add an ADR in `docs/decisions/` with the next free number.
5. Update the docs that your change makes wrong: `README.md` (API table), `docs/ARCHITECTURE.md`, this file.
6. In the task file, set `Status: done` and add a short "Outcome" section: what you built, what you left out, and follow-up tasks. Add new task files for follow-ups.
7. Run `make check-quiet`. It must pass.
8. Commit, push the branch (`git push -u origin <name>`), and open a pull request against `main` with `gh pr create`. Fill in the pull request template. Link the task file.
9. Watch CI with `gh pr checks --watch`. If a check fails, fix it in the same branch and push again. Do not stop at a red PR.
10. Report the PR URL. Leave the worktree in place until the PR is merged. After the merge, `make worktree-rm NAME=...` cleans up.

### CI

`.github/workflows/ci.yml` runs on every pull request and on pushes to `main`. The `backend` job compiles with warnings as errors, checks formatting, runs Credo, checks for unused dependencies, and runs the tests against Postgres + pgvector. The `frontend` job runs the type check, the format check, the tests, and the build. This is the same as `make check`, plus the build. A PR must be green before it is merged. The `backend` and `frontend` jobs are the required checks. GitHub does not enforce this on this private repository (branch protection needs a paid plan), so the rule is a team convention: see `docs/decisions/0010-worktrees-and-pull-requests.md`.

## Definition of done

- `make check` (or `make check-quiet`) passes.
- New behaviour has tests. Tests do not use the network.
- Docs and the task file are up to date.
- No secrets in the repository. Read API keys from environment variables in `config/runtime.exs`, and list them in `.env.example`.
- A pull request is open against `main`, and its CI run is green. Nothing is pushed to `main`.
