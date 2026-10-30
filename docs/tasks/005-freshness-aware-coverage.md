# 005. Freshness-aware coverage

- Status: open
- Area: `Knowseek.Search.Coverage`
- Depends on: none

## Goal

Make coverage reflect whether the data is recent enough. "Stay informed"
queries need new data even when old data matches well.

## Scope

- Add a freshness signal. For example: hits with `fetched_at` (or
  `published_at`) older than a configurable max age do not count as strong.
- Let the caller pass a freshness need (`max_age`) to `POST /api/search` and
  to topics.
- Count distinct documents, not chunks, when you count strong hits.
- Keep the heuristic pure (a function of hits and options) so it stays easy
  to test.

## Acceptance criteria

- Unit tests for each rule.
- README API table and `docs/ARCHITECTURE.md` describe the new parameter.
