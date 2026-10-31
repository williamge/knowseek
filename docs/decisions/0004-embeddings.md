# 0004. Pluggable embeddings, fixed at 1024 dimensions

- Status: Accepted
- Date: 2026-10-30

## Context

We have not chosen an embedding model yet. The `vector` column needs a fixed
size, and tests must not call external APIs.

## Decision

- `Knowseek.Embeddings` is a behaviour. The adapter is chosen in config.
- The default adapter, `Knowseek.Embeddings.Hashing` (ADR 0016 changed the
  default to Ollama; Hashing is now the opt-out and the test adapter), is local and
  deterministic (feature hashing of word tokens). It is a stand-in for dev and
  test, not a semantic model.
- `chunks.embedding` is `vector(1024)`. 1024 is a common output size for
  current embedding models (for example Voyage), and several others can
  truncate to it.

## Consequences

- A model with a different size needs a migration that changes the column and
  rebuilds the HNSW index, plus a job that re-embeds every chunk.
- Changing the model (even at the same size) makes old vectors incomparable
  with new ones. Re-embed everything when you switch.
