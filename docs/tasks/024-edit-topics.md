# 024. Edit and pause topics

- Status: won't do. Topics were removed (task 026, ADR 0015). Following will be redesigned in task 027, so there is nothing left to edit.
- Area: `Knowseek.Topics`, web
- Depends on: 020

## Goal

Change the settings of a topic you follow without unfollowing it first.

## Context

Task 020 made topics unique by normalized query. A repeated follow returns the
existing topic and ignores the settings in the request, and the web UI does not
say so. The only way to change `refresh_interval_seconds` or `max_age_seconds` is
to unfollow and follow again. `active` exists in the schema and
`due_topics/1` honours it, but no API sets it. Task 019 needs both to edit the
interval and to pause a topic.

## Scope

- `PATCH /api/topics/:id` with `refresh_interval_seconds`, `max_age_seconds`, and
  `active`. It uses the same validation as a follow. The query cannot change
  (unfollow and follow again).
- `Knowseek.Topics.update_topic/2` is the only write. Update the JSON view
  and `frontend/src/types.ts`.
- Web: edit the interval and the freshness need, and pause or resume a topic on the
  Topics page. When a repeated follow returns an existing topic with different
  settings than the form asked for, say so ("Already following; settings
  unchanged").
- Optional: if `Discovery.normalize/1` ever changes, `topics.normalized_query`
  must be recomputed. Add a mix task for it and describe when to run it in
  ADR 0012's follow-up note.

## Acceptance criteria

- Tests: a patch changes the interval and `active`. Invalid values return 422. An
  unknown id returns 404. A paused topic is not returned by `due_topics/1`.
- Frontend tests for editing, pausing, and the "already following" message.
- README API table and `docs/ARCHITECTURE.md` describe the endpoint.
