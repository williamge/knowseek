# 017. Re-embed chunks after a model change

- Status: open
- Area: `Knowseek.Documents`, `Knowseek.Embeddings`
- Depends on: 001

## Goal

Re-embed every stored chunk with the configured adapter, so old and new
vectors stay comparable after a model or adapter change (ADR 0004, ADR 0007).

## Context

Changing `EMBEDDINGS_ADAPTER` (for example from `hashing` to `ollama`) or the
model changes how new vectors are made. Chunks stored before the switch keep
their old vectors, and vector search ranks them badly. Re-ingesting does not
fix them, because `Documents.ingest/1` skips a document whose body is
unchanged. Nothing records which model made a vector.

## Scope

- Record the embedding model on each chunk (or document), for example a
  `chunks.embedding_model` column. This is a schema change: add a migration.
- An Oban job that finds chunks whose model differs from the configured one,
  embeds them in batches with `input_type: :document`, and updates them.
  Call the API outside the transaction (architecture rule 5).
- The job pages through chunks, so it can resume after a failure.
- A way to start it (a mix task or a release command).
- Writes go through `Knowseek.Documents` (architecture rule 2).

## Acceptance criteria

- Tests with a stub adapter show that stale chunks get new vectors and
  current chunks are left alone.
- A provider failure stops the job with an error, and a retry continues.

## Out of scope

Changing the vector size (that needs a column migration and an index rebuild).
