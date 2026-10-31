# 027. Rethink following

- Status: open
- Area: product design (no code)
- Depends on: 003, 004

## Goal

Decide what "following" should be in Knowseek, together with the owner.

This is a design and feedback session, not an implementation task. Do it
interactively with the owner **after** news and feed sources exist: task
[003](003-web-search-source.md) (web search source) and task
[004](004-feed-source.md) (feed source) are prerequisites. The owner explicitly
wants to decide what following should be, not to rebuild what was removed
(task 026, ADR 0015). Write no code until the session has produced a decision.

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

## Questions for the session

- What is following for: a standing interest, alerts, a digest, or warming the
  index?
- Who is it for, given that there are no users yet (task 009)?
- What does the user see when something new arrives: a notification, a feed, a
  badge on results?
- How should freshness work: a cadence per topic or per source, what
  `max_age_seconds` means, and how a refresh detects what is new?
- When does the first check run: immediately, or on the schedule?
- How do failures surface?
- Is the unit of following a query, a source or feed, or an entity?
- How does it relate to search-time discovery (`Lookup`)?

## Output

A decision recorded as an ADR, and implementation tasks derived from it. Do not
start those before the owner agrees.
