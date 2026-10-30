# 005. Freshness-aware coverage

- Status: done
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

## Outcome

Built:

- `Coverage.assess/2` counts distinct documents, not chunks. A hit counts
  only when it is relevant and fresh: its `fetched_at` is between
  `max_age_seconds` ago and now. The `:now` option makes the function pure
  for tests.
- `max_age_seconds` on `POST /api/search` (`null` ignores age; 400 for
  other non-positive-integer values) and the
  `Knowseek.Search.max_age_seconds` config default (`nil`).
- `topics.max_age_seconds` (nullable). Without it, a refresh requests
  discovery as before. With it, the refresh runs a lookup with that max age
  and skips discovery when fresh coverage is sufficient.
- `RefreshWorker` now enqueues one `CheckWorker` job per due topic (unique
  per topic, 3 attempts).
- `published_at` on search hits.
- `Documents.ingest/1` updates the fields and `fetched_at` of a document
  with an unchanged body, without re-chunking it.
- Upper bounds on topic `max_age_seconds` and `refresh_interval_seconds`
  (Postgres `integer`), so large values give a 422, not a 500.
- ADR 0006 records these decisions.

Left out:

- The parameter is `max_age_seconds`, not `max_age`, to match
  `refresh_interval_seconds`.
- Freshness uses `fetched_at`, not `published_at` (see ADR 0006).
- There is no topic update endpoint, so a caller sets `max_age_seconds` only
  when it creates a topic.

Follow-ups: none new.
