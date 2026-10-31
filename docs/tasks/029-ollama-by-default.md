# 029. Ollama by default, one command to start

- Status: done
- Area: config, Makefile, scripts, docs
- Depends on: none

## Goal

From the project root, one command gives the good baseline: real semantic
search with a local Ollama, not the word-matching stand-in. See ADR 0016.

## Outcome

Built:

- Default adapter is `Embeddings.Ollama`; `config/test.exs` pins `Hashing`.
  `EMBEDDINGS_ADAPTER=hashing` is the opt-out. No fallback.
- `scripts/ensure-ollama` preflight (CLI, server, model pull, 1024-dimension
  check), run by `make setup`, `dev`, `iex`, `start`, and `make ollama`.
- `make start`: API and web UI in one terminal via `scripts/start`; Ctrl-C and
  SIGTERM stop both process trees.
- `FallbackController` returns 503 for `{:error, {:ollama | :voyage, _}}`
  (was 500), with a test.
- README, AGENTS.md, `.env.example`, ARCHITECTURE, compose default, ADR 0007 note.

Left out: model-mismatch detection and re-embedding (task 017). The Docker
container still needs host Ollama or `EMBEDDINGS_ADAPTER=hashing` (task 025).
