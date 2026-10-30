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
| `make test` | Run the test suite |
| `make ollama` | Optional: check that a native Ollama runs and pull `bge-m3` (about 1.2 GB) for `EMBEDDINGS_ADAPTER=ollama` |
| `make check` | Compile with warnings as errors, format, Credo, tests. **Must pass before you finish.** |
| `make check-quiet` | Same as `make check`, but prints only a summary or the failures. Agents use this one. |

Single test file: `cd backend && mix test test/knowseek/search_test.exs`.

To save tokens:

- While you work, run only the test files that you change (add `--failed` to re-run only failures).
- Run `make check-quiet` one time at the end, not after each edit.
- Do not read whole large files when a `grep` or a line range answers the question.

New migration: `cd backend && mix ecto.gen.migration name_with_underscores`.

### Databases and parallel workspaces

One Postgres container (`docker compose`, project name `knowseek`) serves every workspace. Each Conductor workspace gets its own databases, named from `CONDUCTOR_WORKSPACE_NAME` (for example `knowseek_dev_search_index_service`). You can run tests and servers in many workspaces at once. If a database is missing, run `make setup` again. Outside Conductor (for example in iTerm), `CONDUCTOR_WORKSPACE_NAME` is not set, so commands use the shared `knowseek_dev` and `knowseek_test` databases.

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

## Testing rules

- Tests never call the network. Stub HTTP with `Req.Test` (pass `plug: {Req.Test, Name}` through config) and use fake sources and adapters from `test/support/`.
- Oban runs in `:manual` testing mode. Assert with `assert_enqueued/1`, and run jobs with `perform_job/2`.
- Use the fixtures in `test/support/fixtures.ex`. Add new fixtures there.
- Every new public function gets a test. Every bug fix gets a regression test.

## How to work on a task

1. Pick a task in `docs/tasks/` (or take the one you were given). Read the whole task file.
2. Work on one task per branch or workspace. Keep the change small enough to review.
3. If you make a decision that a later agent needs to know about (new dependency, new service, schema change, changed contract), add an ADR in `docs/decisions/` with the next free number.
4. Update the docs that your change makes wrong: `README.md` (API table), `docs/ARCHITECTURE.md`, this file.
5. In the task file, set `Status: done` and add a short "Outcome" section: what you built, what you left out, and follow-up tasks. Add new task files for follow-ups.
6. Run `make check-quiet`. It must pass.

## Definition of done

- `make check` (or `make check-quiet`) passes.
- New behaviour has tests. Tests do not use the network.
- Docs and the task file are up to date.
- No secrets in the repository. Read API keys from environment variables in `config/runtime.exs`, and list them in `.env.example`.
