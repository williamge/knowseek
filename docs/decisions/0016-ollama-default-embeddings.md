# 0016. Ollama is the default embedding adapter, checked by a preflight

- Status: Accepted
- Date: 2026-10-31

Changes the default set in [0007](0007-embedding-providers.md).

## Context

The default adapter was `Hashing`, which matches words, not meaning. A fresh
clone therefore did not give the baseline the owner expects: real semantic
search. Getting it took a hand-made `.env`, `make ollama`, and two terminals.
Switching adapters also leaves old vectors in the database that cannot be
compared with new ones.

## Decision

- Outside tests the default adapter is `Knowseek.Embeddings.Ollama` (`bge-m3`).
  `config/test.exs` pins `Hashing`, so tests never need Ollama or the network.
  `EMBEDDINGS_ADAPTER=hashing` stays a valid, explicit opt-out; `voyage` is
  unchanged.
- No fallback to `Hashing` when Ollama is unreachable. Ingest and search return
  their existing `{:error, _}` results (task 001). The API turns a provider
  error into HTTP 503 with a JSON body (it was a generic 500).
- `scripts/ensure-ollama` is the preflight. With the ollama adapter it checks
  that the CLI exists and the server answers on `$OLLAMA_URL`, pulls
  `$OLLAMA_MODEL` if missing (about 1.2 GB, first run only), and makes one tiny
  `/api/embed` call to check that the output has 1024 dimensions (the call is
  cheap and also warms the model). With another adapter it exits silently.
  On success it prints one line. On failure it exits 1 with the fix and the
  opt-out. `make setup`, `make dev`, `make iex`, and `make start` run it after
  `db-up`; `make ollama` is a thin wrapper. `make test` and `make check` do not.
- `make start` runs db-up, the preflight, migrations, then the API and the web
  UI in one terminal (`scripts/start`). Each child runs in its own process
  group, and the script's INT/TERM trap signals both groups, so no BEAM or
  node process is left behind. `make dev` and `make web` still work alone.
- The container (`docker compose --profile app`) reaches the host Ollama through
  `APP_OLLAMA_URL` (default `http://host.docker.internal:11434`); compose now
  defaults `EMBEDDINGS_ADAPTER` to `ollama` too. Task 025's container smoke test
  must set `EMBEDDINGS_ADAPTER=hashing` or provide an Ollama service.

## Alternatives considered

- **Keep hashing as the default.** Rejected: it is not the baseline the owner
  wants, and people forget to switch.
- **Fall back to hashing when Ollama is absent.** Rejected: it silently builds
  an index whose vectors are incomparable with the Ollama ones.
- **Ollama as a docker-compose service.** Rejected for now: Docker on macOS has
  no GPU access, so it is slow. Native Ollama is the baseline.

## Consequences

- Dev and the prod baseline depend on Ollama on the host, and the first run
  downloads about 1.2 GB. Remote workspaces need `EMBEDDINGS_ADAPTER=hashing`.
- After switching an existing database from hashing to Ollama (or back), run
  `make db-reset`. Re-ingest skips unchanged documents, so it does not
  re-embed.
- Nothing detects a model mismatch yet (which model embedded which chunk). Task
  017 stays open for exactly this.
