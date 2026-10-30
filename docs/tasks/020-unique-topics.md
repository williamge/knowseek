# 020. Topics unique by query

- Status: open
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
