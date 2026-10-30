# 014. One search hit per document

- Status: open
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
