# 001. Real embedding adapter

- Status: open
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
