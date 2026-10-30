# 0002. Postgres + pgvector as the single datastore

- Status: Accepted
- Date: 2026-10-30

## Context

We need full-text search, vector search, relational metadata, and a job queue.

## Decision

Use one Postgres database with the pgvector extension for all of them:
`tsvector` + GIN for full-text, `vector` + HNSW for semantic search, normal
tables for metadata, and Oban's table for jobs. Local dev runs the
`pgvector/pgvector:pg17` image via `docker-compose.yml`.

## Consequences

- One system to run, back up, and reason about. Writes are transactional
  across documents, chunks, and jobs.
- If the index outgrows Postgres, `Knowseek.Search` is the only module that
  reads it, so a dedicated engine (OpenSearch, Vespa, etc.) can replace it
  behind the same interface.
