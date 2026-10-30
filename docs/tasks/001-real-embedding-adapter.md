# 001. Real embedding adapter

- Status: done
- Area: `Knowseek.Embeddings`
- Depends on: none

## Goal

Add an embedding adapter that calls a real model, so semantic search matches
meaning and not only shared words.

## Context

`Knowseek.Embeddings.Hashing` is a stand-in. The column is `vector(1024)`
(ADR 0004). Voyage AI (`voyage-3.5`, 1024 dims) is the suggested first
provider. A local option (Ollama, or Bumblebee in-process) is also fine; write
an ADR for the choice.

## Scope

- `Knowseek.Embeddings.<Provider>` implementing the behaviour, using `Req`.
- Batch requests (respect the provider's batch and token limits).
- Distinguish query vs document input if the provider supports it (Voyage
  `input_type`). This needs a small change to the behaviour: add an option.
- API key from an environment variable in `config/runtime.exs`, listed in
  `.env.example`. Keep `Hashing` as the default when no key is set, and in tests.
- Retry on 429 and 5xx with backoff.

## Acceptance criteria

- Unit tests with `Req.Test` stubs cover success, batching, and errors.
- `Documents.ingest/1` and `Search.search/2` return `{:error, _}` (not crash)
  when the provider fails.
- ADR records the model choice.

## Out of scope

Re-embedding existing chunks (write a follow-up task for an Oban job that does it).

## Outcome

Built:

- `Knowseek.Embeddings.Ollama`: free, local. Calls Ollama's `/api/embed`
  with `bge-m3` (1024 dims) in batches of 32. Ollama runs natively (Homebrew),
  so it uses the GPU. `make ollama` checks that it runs and pulls the model.
- `Knowseek.Embeddings.Voyage`: hosted. `voyage-3.5` (1024 dims). It batches
  by count (128) and estimated tokens (100K).
- Both retry on 408, 429, 5xx, and transport errors (`retry: :transient`) and
  return `{:error, {:ollama | :voyage, ...}}` on failure.
- `Embeddings.embed/2` takes `input_type: :document | :query`. Ingest sends
  `:document`, search sends `:query`. Voyage uses it; the others ignore it.
- `EMBEDDINGS_ADAPTER` (`hashing`, `ollama`, `voyage`) selects the adapter in
  `config/runtime.exs`. `hashing` stays the default and the test adapter.
  The Makefile now loads `.env`. All variables are in `.env.example`.
- Tests in `test/knowseek/embeddings/ollama_test.exs` and `voyage_test.exs`
  use `Req.Test` stubs: success, batching, retries, errors, wrong vector size,
  and `Documents.ingest/1` and `Search.search/2` with a failing provider.
- ADR 0006 records the choice.

Left out:

- Re-embedding existing chunks: task 014.
- Bumblebee in-process. ADR 0006 explains why.
- Exact token counting for Voyage. The adapter estimates tokens from byte size.
- No test covers the `EMBEDDINGS_ADAPTER` parsing in `config/runtime.exs`.
