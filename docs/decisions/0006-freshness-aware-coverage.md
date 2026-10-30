# 0006. Freshness-aware coverage; per-topic refresh checks

- Status: Accepted
- Date: 2026-10-30

## Context

Coverage counted every relevant hit, however old. A "stay informed" query
with only old matches counted as covered, so no discovery ran. Coverage also
counted chunks, so one long document could make a query look covered.

Topics did not use coverage at all. Every due topic requested discovery,
even when the index already had fresh documents for it.

## Decision

- `Knowseek.Search.Coverage` counts distinct documents with a hit that is
  relevant and fresh. A hit is fresh when its document's `fetched_at` is
  between `max_age_seconds` ago and now. `nil` (the default) ignores age.
- Freshness uses `fetched_at`, not `published_at`. The question that
  coverage answers is "should we seek again?". A recent fetch already
  answered it, even when the content itself is old. A `published_at` from
  a source can also be wrong or in the future.
- When `Documents.ingest/1` sees an unchanged body, it updates the other
  fields and `fetched_at`, but does not re-chunk or re-embed. So
  `fetched_at` means "the last time a fetch saw this content".
- `POST /api/search` accepts `max_age_seconds`. The config key
  `Knowseek.Search.max_age_seconds` gives the default. `null` in a request
  ignores age.
- `topics.max_age_seconds` is a new nullable column. `NULL` keeps the old
  behaviour: every refresh requests discovery. With a value, a refresh runs
  `Knowseek.Lookup.run/2` with that max age, and discovery runs only when
  fresh coverage is not sufficient. The default is not tied to
  `refresh_interval_seconds`: documents from the previous refresh are about
  one interval old, so that default would depend on job timing.
- `Topics.RefreshWorker` enqueues one `Topics.CheckWorker` job per due
  topic. A check retries on its own, and one failing topic does not stop
  the others.

## Consequences

- Topics with `max_age_seconds` and enough fresh documents do not call
  external sources.
- Each check of such a topic embeds the topic query. With a paid embedding
  provider, this is one API call per check.
- Set `max_age_seconds` clearly larger or smaller than
  `refresh_interval_seconds`. Near the interval, whether a refresh seeks
  again depends on job timing.
- `published_at` does not affect coverage. Ranking by recency is a separate
  concern.
- `Coverage.assess/2` takes `:now`, so tests can fix the clock.
