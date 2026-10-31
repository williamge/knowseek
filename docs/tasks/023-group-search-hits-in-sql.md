# 023. Group search hits by document in SQL

- Status: open
- Area: `Knowseek.Search`
- Depends on: 014

## Goal

Make search fill `limit` documents whenever the index has that many, even when
a few documents have many matching chunks each.

## Context

Task 014 returns one hit per document. It still fetches `limit * candidate_factor`
chunks from each ranked list (full-text and vector) and groups them in
Elixir. The default `candidate_factor` is 40, about the chunk count of a long
Wikipedia article. If several documents each have more matching chunks than
that, they use up the candidates, and search returns fewer hits than `limit`
although other documents match. Manually ingested documents have no size cap, so
this can happen. See ADR 0011 and the Outcome of task 014.

The vector query also sets `hnsw.ef_search` per query (`Search.ef_search/1`),
because the HNSW index returns at most 40 rows by default. Latency was measured
only on a small index (about 1,400 chunks, median about 17 ms at `limit` 10).

## Scope

- Rank documents in SQL: for each list, take the best chunk per document (a
  window function or `DISTINCT ON (document_id)`), then limit to the top
  `limit * k` documents, with a small `k` (for example 2 or 3).
- Keep the best chunk's fields on the hit and the other matching chunks in
  `passages`, as in ADR 0011.
- Decide whether `candidate_factor` and the `ef_search` override are still
  needed. Remove them if they are not. Update `docs/ARCHITECTURE.md` and
  write an ADR that supersedes the relevant part of 0011.
- Measure latency before and after on an index with at least 50,000 chunks
  (the hashing embedder is enough) at the default and the maximum `limit`.
  Put the numbers in the Outcome.

## Acceptance criteria

- A test with several documents that each have more matching chunks than the old
  `candidate_factor` fills `limit` with different documents. It fails on the
  current code.
- Existing search tests (score is the best chunk's, passages are capped, ties keep
  the fused order) still pass.
- Latency numbers for both versions are in the Outcome.
