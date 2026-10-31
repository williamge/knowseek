# 029. Ollama by default, one command to start

- Status: done
- Area: config, Makefile, scripts, docs
- Depends on: none

## Goal

From the project root, one command gives the good baseline: real semantic
search with a local Ollama, not the word-matching stand-in. See ADR 0016.

## Scope

- Default adapter is `Embeddings.Ollama`; `config/test.exs` pins `Hashing`;
  `EMBEDDINGS_ADAPTER=hashing` is the opt-out. No fallback to hashing.
- `scripts/ensure-ollama` preflight (CLI, server, model pull, 1024-dimension
  check), run by `make setup`, `dev`, `iex`, `start`, `db-reset`, and `make ollama`.
- `make start`: API and web UI in one terminal; Ctrl-C, SIGTERM, and SIGHUP stop both.
  `make dev` and `make web` keep working separately.
- Provider errors (all shapes the adapters return) become HTTP 503.
- A discovery job that ingests nothing while some candidate failed returns an
  error, so Oban retries it.
- `make worktree` defaults a new worktree to `EMBEDDINGS_ADAPTER=hashing`.
- Docs: README, AGENTS.md, `.env.example`, ARCHITECTURE, ADR 0016, notes in
  ADRs 0004, 0007, 0014; task 025 scope.

## Acceptance criteria

- `scripts/ensure-ollama` prints one line when all is well; exits 1 with the
  fix when the CLI or server is missing; pulls a missing model; exits 0
  silently for other adapters.
- With the default config, `cos(cat, kitten) > cos(cat, carburetor)`, and
  `Search.search/2` ranks the semantically closer document first.
- `make start` serves the API and the UI (with `/api` proxied); a terminal
  Ctrl-C leaves no listener behind.
- With Ollama unreachable, `make dev` stops in the preflight, and
  `POST /api/search` and `POST /api/documents` return 503 JSON.
- `make check-quiet` passes without Ollama.

## Outcome

Built everything in Scope.

Left out: model-mismatch detection and re-embedding (task 017). The container
still needs host Ollama or `EMBEDDINGS_ADAPTER=hashing` (task 025).
