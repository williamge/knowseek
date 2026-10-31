# 020. Topics unique by query

- Status: done (the feature was removed later: see task 026 and ADR 0015)
- Area: `Knowseek.Topics`, migration, web
- Depends on: none

## Goal

Following the same query twice creates two topics. Both get refreshed, so
discovery runs twice, and the web UI cannot unfollow both with one click.

## Scope

- Add a unique index on the normalized query (`Knowseek.Discovery.normalize/1`
  rules: lowercase, collapsed whitespace). A migration needs to merge the
  duplicates that exist.
- `POST /api/topics` for a query that is already followed returns the existing
  topic (or `409`). Pick one and document it.
- Web: the follow button and the Topics page form use the result, so a second
  follow does not show an error.
- Write an ADR for the schema change.

## Acceptance criteria

- A test shows that two follows of "Rust" and "  rust " give one topic.
- The migration handles a database that already has duplicates.

## Outcome

Built:

- `topics.normalized_query` (`NOT NULL`, unique index), filled by
  `Topic.changeset/2` through `Discovery.normalize/1`.
- A migration that backfills and merges existing duplicates through
  `Knowseek.Topics.Deduplicate` (oldest row kept; shortest interval; active if
  any was; `max_age_seconds` null if any was null, else the smallest;
  latest `last_refreshed_at`). Tested with duplicates, and run against a
  database that had them.
- `Topics.follow_topic/1` replaces `create_topic/1`. The unique index decides,
  so simultaneous follows give one topic. `POST /api/topics` returns the
  existing topic with `200` (new: `201`), unchanged.
- Web: `useTopics.follow` does not add a topic that is already in the list.
  Follow button and Topics page form show no error on a repeated follow.
- ADR 0012; README API table and ARCHITECTURE updated.

Left out / follow-ups (no task file added):

- No way to change the settings of an existing topic (`PATCH /api/topics/:id`).
  Today, unfollow and follow again.
- If `Discovery.normalize/1` changes, `normalized_query` must be recomputed
  with a new migration.
