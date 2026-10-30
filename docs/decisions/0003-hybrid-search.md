# 0003. Hybrid search with reciprocal rank fusion

- Status: Accepted
- Date: 2026-10-30

## Context

Keyword search is precise for names and rare terms. Vector search finds
paraphrases. Neither is enough alone, and their scores are not comparable.

## Decision

Search chunks, not whole documents. Run both searches, take the top
`4 × limit` from each, and merge them with reciprocal rank fusion
(`score = Σ 1 / (60 + rank)`). Fusion uses ranks only, so no score
normalization is needed.

## Consequences

- Two queries per search. Both use indexes, so this is cheap at current scale.
- Several chunks from the same document can fill the results. Grouping by
  document is a possible follow-up.
