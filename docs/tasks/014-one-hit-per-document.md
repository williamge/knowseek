# 014. One search hit per document

- Status: done
- Area: `Knowseek.Search`, `Knowseek.Search.Coverage`, web (`SearchJSON`)
- Depends on: none

## Goal

Return one hit per document, not one hit per chunk, so that a long document
cannot fill the result list or make coverage look stronger than it is.

## Context

`Search.search/2` ranks chunks (about 1,200 characters each) and returns the
top `limit` chunks as hits. Before discovery sources existed, every document
fit in one chunk, so a chunk and a document were the same thing. A Wikipedia
article (task 002) has up to about 35 chunks.

Example from the dev database, query "octopus intelligence", `limit` 10:

| Document | Hits in the top 10 | Chunks in the index |
| --- | --- | --- |
| Other Minds | 5 | 9 |
| Cephalopod intelligence | 3 | 13 |
| Octopus | 2 | 40 |

This causes two problems:

1. **Less variety.** Ten hits show only three documents. Other relevant
   documents fall out of the top 10.
2. **Inflated coverage.** `Coverage.assess/2` counts strong hits. One
   document with three matching chunks gives `:sufficient`, so `Lookup`
   does not request discovery, although the index has only one source for
   the query.

## Scope

- Group the fused chunk results by `document_id`. Each document becomes one
  `Knowseek.Search.Hit`.
- The document's score is the score of its best chunk. Do not sum chunk
  scores: a sum favours long documents only because they are long.
- Keep the best chunk's fields at the top level of the hit (`chunk_id`,
  `content`, ranks, `similarity`), so the current JSON shape stays valid.
- Add `passages` to the hit: the other matching chunks of that document, in
  score order, each with `chunk_id`, `content`, and `score`. Cap the list
  (for example 3, configurable in `Knowseek.Search` config). Answer
  synthesis (task 008) can use these passages as extra context.
- Fetch enough chunk candidates that grouping still fills `limit` documents
  in most cases. Today the search fetches `limit * 4` chunks from each
  list. Measure, and raise the factor if needed. If there are fewer
  documents than `limit`, return fewer hits.
- Coverage: a document is strong if any of its chunks is strong. Because
  each hit is now one document, counting strong hits counts documents.
- Update `KnowseekWeb.SearchJSON` to render `passages`.

## Acceptance criteria

- Tests: a document with many matching chunks gives one hit, with the best
  chunk at the top level and the other chunks in `passages`.
- Tests: hits come from different documents when the index has them, even
  if one document has more matching chunks than `limit`.
- Tests: one document with several strong chunks gives `:partial`, not
  `:sufficient` (with the default `min_strong_hits` of 3).
- README API table and `docs/ARCHITECTURE.md` describe the hit shape. Add
  an ADR for the changed response contract.

## Notes

Task 005 also says "count distinct documents, not chunks". If this task
lands first, that part of 005 is done. Say so in the Outcome, and update
task 005 so that its agent does not do the work twice.

Task 005 landed first. `Coverage.assess/2` already counts distinct
documents (`Enum.uniq_by(& &1.document_id)`), and
`test/knowseek/search_test.exs` already tests that one document with many
strong chunks counts once. Keep that rule when hits become documents.

## Outcome

Built:

- `Search.search/2` groups relevant fused chunks by `document_id`. A hit is a
  document: its score and chunk fields come from its best chunk (no sum).
  `Hit.passages` holds the other matching chunks (`chunk_id`, `content`,
  `score`), best first, capped by `max_passages` (config, default 3; also a
  search option). `SearchJSON` renders `passages`; all old fields stay.
- Candidate fetch: `candidate_factor` (config) replaces the fixed `limit * 4`.
  Default 40. Measured in a throwaway test with the hashing adapter: 5
  equally relevant 35-chunk articles plus 15 short documents, `limit` 10.
  Factor 4 gave 2 hits, 10 gave 3, 20 gave 10; at `limit` 3 or 5, factor 20
  still underfilled (2 and 3 hits) and 40 filled (3 and 5). See ADR 0011.
- The HNSW index returns at most `hnsw.ef_search` rows (default 40), so the
  vector query now sets it per query (`set_config(..., true)`, at most 1000).
  Without that the factor would not raise the vector list above 40.
- Frontend: `types.ts` has `Hit.passages`; `groupHits` no longer groups
  client-side, it shapes each hit and its passages for the card. "New"
  detection after discovery compares document ids, not chunk ids.
- Tests for the three acceptance criteria plus score, cap, and fewer-hits.

Task 005's "count distinct documents" already existed in `Coverage.assess/2`.
Task 005 is done, so it needs no change. The coverage rule is kept, and now
counts documents because each hit is one.

Left out: the worst case is not guaranteed. Several documents that all have
more than `candidate_factor` matching chunks can still underfill `limit`.
Exact grouping in SQL (window function over chunks per document) is a
possible follow-up. Using `passages` in answer synthesis is task 008.

Latency: 1,403 chunks, median about 17 ms for factor 4 and 40 at `limit` 10; larger indexes and the maximum limit are unmeasured.
