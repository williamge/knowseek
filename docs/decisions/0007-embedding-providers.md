# 0007. Embedding providers: Ollama locally, Voyage AI hosted

- Status: Accepted
- Date: 2026-10-30

## Context

The hashing stand-in (ADR 0004) matches words, not meaning. We need a real
embedding model. The column is `vector(1024)`, so the model must output 1024
dimensions. We want a free option for development, and tests must not call
the network.

Options:

- **Ollama** with `bge-m3`: free, local server, no API key. `bge-m3` outputs
  1024 dimensions, is multilingual, takes 8K tokens per text, and needs no
  query or document prefix. The model is about 1.2 GB.
- **Voyage AI** (`voyage-3.5`): hosted and paid per token. 1024 dimensions by
  default, separate `query` and `document` input types, large batch limits.
- **Bumblebee in-process**: no external service, but adds large dependencies
  (Nx, EXLA) and model downloads to every build and every CI run.

## Decision

- Add two adapters that use `Req`:
  - `Knowseek.Embeddings.Ollama`: calls `POST /api/embed` on a local Ollama
    server. Default model `bge-m3`. Batches of 32 texts.
  - `Knowseek.Embeddings.Voyage`: calls the Voyage embeddings API. Default
    model `voyage-3.5` with `output_dimension: 1024`. Batches of at most 128
    texts and about 100K estimated tokens (bytes / 3). The API limits are
    1000 texts and 320K tokens.
- `EMBEDDINGS_ADAPTER` (`hashing`, `ollama`, or `voyage`) selects the adapter
  in `config/runtime.exs`. The default is `hashing`, so a fresh workspace needs
  no extra service. Tests always use `Hashing` or `Req.Test` stubs.
- Ollama runs natively on the developer machine (`brew install ollama`,
  `brew services start ollama`), not in Docker. On macOS, Docker containers
  cannot use the GPU (Metal), so a container would run the model on the CPU.
  `make ollama` checks that the server answers and pulls the model.
- One Ollama server on `localhost:11434` serves every local Conductor
  workspace, like the shared Postgres container (ADR 0005).
- The Makefile loads `.env`, so a workspace can set `EMBEDDINGS_ADAPTER=ollama`
  once.
- The `Knowseek.Embeddings` behaviour gets an `:input_type` option
  (`:document` or `:query`). `Documents.ingest/1` passes `:document`, and
  `Search.search/2` passes `:query`. Voyage uses it; Ollama and Hashing
  ignore it.
- Both adapters retry on 408, 429, 5xx, and transport errors, with exponential
  backoff (`Req` `retry: :transient`, 3 retries). Other errors fail fast. A
  failure returns `{:error, {:ollama | :voyage, ...}}`, and callers already
  propagate `{:error, _}` from `Embeddings.embed/2`.

## Consequences

- Semantic search works for free on a dev machine after Ollama is installed
  and `make ollama` has pulled the model.
- Ollama is a host dependency outside Docker Compose. `make setup` does not
  install it, and remote workspaces cannot reach it.
- Parallel agents share one Ollama server. It queues requests, so heavy
  ingest in many workspaces at once is slower.
- Vectors from different adapters or models are not comparable. After a
  switch, re-embed every chunk. Until task 017 adds a job for that, reset the
  dev database. Re-ingesting does not help, because `Documents.ingest/1`
  skips a document whose body is unchanged.
- Search makes one embedding call per query, so its latency includes that call
  and any retries.
- A model with another output size needs a column migration (ADR 0004). The
  dispatcher rejects wrong-size vectors with `{:error, {:dimension_mismatch, _}}`.
