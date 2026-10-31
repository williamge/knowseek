# 0011. One search hit per document

- Status: Accepted
- Date: 2026-10-30

## Context

`Search.search/2` returned one hit per chunk. A Wikipedia article has up to
about 35 chunks, so one document could fill the list (in the dev database,
"octopus intelligence" gave 10 hits from 3 documents) and one document with
three matching chunks made coverage `:sufficient`.

## Decision

- A hit is a document. Relevant fused chunks are grouped by `document_id`.
- The document's `score` is its best chunk's score. Scores are not summed: a
  sum favours long documents only because they are long.
- The best chunk's fields (`chunk_id`, `content`, `keyword_rank`,
  `semantic_rank`, `similarity`) stay at the top level. The JSON shape stays
  valid; all existing fields remain.
- New field `passages`: the document's other relevant chunks, best first,
  each `{chunk_id, content, score}`, at most `max_passages` (config, default
  3; `:max_passages` search option).
- `candidate_factor` (config) sets how many chunks each ranked list fetches:
  `limit * candidate_factor`. It was a fixed 4. A throwaway measurement
  (hashing adapter; 5 equally relevant 35-chunk documents plus 15 short
  ones) gave, at `limit` 10: factor 4 -> 2 hits, 10 -> 3, 20 -> 10. At
  `limit` 3 and 5, factor 20 gave 2 and 3 hits; factor 40 gave 3 and 5. The
  default is 40, the chunk count of the largest article we index. Only ids
  and ranks are fetched, so the cost is small.
- pgvector's HNSW scan returns at most `hnsw.ef_search` rows (40 by
  default). The vector query raises it for its own transaction to the
  candidate count (at most 1000), otherwise the factor would not apply to it.
- Coverage counts documents with a strong hit. `Coverage.assess/2` already
  deduplicated by `document_id` (task 005); it keeps doing so.

## Consequences

- Clients that counted hits as chunks now get documents. `hits` has at most
  one entry per `document_id`, and may have fewer than `limit`.
- The worst case is still not guaranteed: more matching-heavy documents than
  the candidate budget covers can underfill `limit`. Grouping in SQL would
  remove the limit and is a possible follow-up.
- The vector query runs in a short transaction to set `hnsw.ef_search`.
- Answer synthesis (task 008) can use `passages` as extra context.
