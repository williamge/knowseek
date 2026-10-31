# 027. Rethink following

- Status: folded into 028
- Area: product design (no code)
- Depends on: none

The questions about following (purpose, audience, notification, cadence,
failures, unit of following) now live in
[028](028-live-facts-for-entities.md). Decide them there, in the session.

## What the removed version did

- `POST /api/topics` inserted one row in `topics` (`query`, `normalized_query`,
  `active`, `refresh_interval_seconds` default 86400, `max_age_seconds`
  nullable, `last_refreshed_at`) and enqueued nothing. Topics were unique by
  `md5(normalized_query)`.
- An Oban cron entry every 15 minutes enqueued one `CheckWorker` per due topic.
- `CheckWorker` called `Discovery.request` (or `Lookup.run` when
  `max_age_seconds` was set). That enqueued a `SeekWorker`, which asks all
  sources (only Wikipedia) and calls `Documents.ingest`.
- The topic was marked refreshed as soon as the seek job was enqueued, not when
  it succeeded.
- The follow button never sent `max_age_seconds`.
- The UI gave no feedback about what a follow found or when it last ran.
- Topics were global: there are no users.
