# 0015. Remove the follow-topic feature

- Status: Accepted
- Date: 2026-10-31

Supersedes [0012](0012-unique-topics.md). Removes the per-topic parts of
[0006](0006-freshness-aware-coverage.md).

## Context

Users could follow a query as a "topic". An Oban cron job checked the due
topics every 15 minutes and requested discovery for them. The owner never asked
for this feature explicitly. The one convincing use case is contemporary
information, such as ongoing news. That needs news and feed sources, and they do
not exist yet (tasks 003 and 004). With only Wikipedia as a source, following a
query re-fetches the same encyclopedic articles. The feature also had no users
to belong to, no feedback in the UI, and its own open backlog (task 024).

## Decision

Remove the feature entirely, with no shim, flag, or deprecated path. Redesign
it after news sources exist. Task 027 is a design session with the owner. It is
not an implementation task, and no code is written before the session decides
what following should be.

Removed:

- Backend: `Knowseek.Topics` with `Topic`, `RefreshWorker`, `CheckWorker`, and
  `Deduplicate`; `TopicController` and `TopicJSON`; the `/api/topics` routes;
  the Oban cron entry and the `Oban.Plugins.Cron` plugin; the `default` queue;
  the topic fixtures and tests.
- Database: the `topics` table, and the queued or retained Oban jobs of the two
  removed workers (migration `drop_topics`).
- Frontend: the follow button, the topics page and its `/topics` route, the
  topics chips on the home page, the corner nav link, `useTopics`, the topic
  API calls and types, and the styles only they used. The `page` field of the
  route and the 204 branch of the API client had no other user and went too.
- Docs: the API table, the architecture diagram, context table, data model, and
  queue table, and the context list in `AGENTS.md`.

Kept:

- `max_age_seconds` on `POST /api/search`, `Lookup.run/2`, `Search.search/2`
  and `Search.Coverage`, with `published_at` on hits. `CheckWorker` was one
  caller, but the option is a search feature of task 005 and ADR 0006 with its
  own controller validation, tests, and docs. It stays.
- The `discovery` queue, `SeekWorker`, `Lookup`, and `Discovery.request/1`.
- The Oban `Pruner` plugin.

Decisions on the migrations:

- A new migration drops `topics`. It first deletes the `oban_jobs` rows of
  `Knowseek.Topics.RefreshWorker` and `Knowseek.Topics.CheckWorker`. Without
  that, a database with queued, scheduled, or retryable jobs keeps jobs that
  fail forever with an unknown worker. Its `down` recreates the final table
  schema, including the `md5(normalized_query)` unique index. It does not
  restore rows.
- The older migration `20261031002441` called `Knowseek.Topics.Deduplicate`,
  which is gone. Rather than keep a module only for an old migration, the call
  is replaced by `DELETE FROM topics`. On a fresh database the table is empty,
  so nothing changes. A database that already ran the migration does not run it
  again. A database that has not reached it yet drops the table a few seconds
  later in the same run, so discarding its rows loses nothing the later
  migration would not delete. The alternative, copying about 60 lines of merge
  SQL into the migration so that data that is about to be dropped gets merged,
  was rejected.
- Dropping the `default` queue: no other worker used it. A future worker that
  needs it adds it again.

## Consequences

- No way to follow a query. Existing topic rows are deleted. This is
  accepted: the data is a list of queries, and no user depends on it.
- `max_age_seconds` is now only a search option.
- Tasks 020 and 024 are marked as superseded. Task 019 no longer lists topic
  work. Task 004 (feed source) lost its dependency on topics and needs its
  scope reconsidered with task 027.
- Task 027 holds the questions for the redesign.
