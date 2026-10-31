# 0012. Topics are unique by normalized query

- Status: Accepted
- Date: 2026-10-30

## Context

Following the same query twice created two topics. `RefreshWorker` refreshed
both, so discovery ran twice for one interest, and the web UI could not
unfollow both with one click. `Knowseek.Discovery.normalize/1` already treats
"Rust" and "  rust " as one query for discovery jobs, but topics did not.

## Decision

- `topics.normalized_query` is a new `text NOT NULL` column with a unique
  index (`topics_normalized_query_index`). `Topic.changeset/2` fills it by
  calling `Knowseek.Discovery.normalize/1`, so the rules (lowercase, collapsed
  whitespace) live in one place. `topics.query` keeps the text the user typed.
- `Knowseek.Topics.create_topic/1` is replaced by `follow_topic/1`. It returns
  `{:ok, topic, :created}`, `{:ok, topic, :existing}`, or `{:error, changeset}`.
  It inserts first and lets the unique index decide, then reads the stored
  topic when the insert hit the constraint. It does not check first, so two
  simultaneous follows of one query give one topic and both callers get it.
- `POST /api/topics` for a query that is already followed returns the existing
  topic with **`200`**; a new topic still returns `201`. We chose the existing
  topic over `409` because following is idempotent: the caller wants the
  topic followed, and it is. The stored topic is returned **unchanged**. The
  `refresh_interval_seconds`, `max_age_seconds`, and `active` of the request
  are ignored, so a repeated follow cannot silently change a schedule. Invalid
  settings still return `422`, also for an existing query. There is no update
  endpoint; to change settings, unfollow and follow again.
- The migration (`Knowseek.Topics.Deduplicate`, called from the migration)
  backfills `normalized_query` and merges the duplicates that exist. Per
  group of topics with one normalized query:
  - The **oldest** row (`inserted_at`, then `id`) is kept, with its `id` and
    `query` text. The others are deleted. Queued `CheckWorker` jobs of
    deleted topics do nothing, because the worker skips missing topics.
  - `refresh_interval_seconds`: the shortest of the group.
  - `active`: `true` if any row was active.
  - `max_age_seconds`: `NULL` if any row has `NULL`, because `NULL` means
    "every refresh seeks new data" (ADR 0006), and the stricter need wins.
    Otherwise the smallest value.
  - `last_refreshed_at`: the latest of the group, so the merged topic is not
    refreshed again right away.
- The backfill calls `Discovery.normalize/1` from Elixir, not an equivalent
  SQL expression, because Postgres `lower()` and Elixir `String.downcase/1`
  can differ for some Unicode input, which would leave duplicates that the
  index does not see. The merge itself is plain SQL on the table, not on the
  `Topic` schema. The migration is not reversible for the merge: `down` drops
  the index and the column, and the deleted rows stay deleted.
- The web client (`useTopics.follow`) adds the returned topic to its list only
  if its id is not there yet, so a repeated follow shows no error and no
  duplicate row.

## Consequences

- One interest costs one refresh, and one click unfollows it.
- Clients that need to know whether a follow created the topic read the
  status code (`201` or `200`).
- If `Discovery.normalize/1` changes later, stored `normalized_query` values
  go stale. That change needs a migration that recomputes them and merges the
  new duplicates, using `Deduplicate` as the starting point.
- Settings of an existing topic cannot be changed through the API yet. A
  follow-up can add `PATCH /api/topics/:id`.
