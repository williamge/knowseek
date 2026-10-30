# 006. Tell callers when discovery finishes

- Status: open
- Area: `Knowseek.Lookup`, `Knowseek.Discovery`, web
- Depends on: none

## Goal

A search that triggers discovery currently returns a job id and nothing else.
Let the caller find out when new results are available.

## Scope

- Persist searches: a `searches` table (query, coverage, job id, status,
  timestamps). `POST /api/search` returns a `search_id`.
- `GET /api/searches/:id` returns the status (`pending`, `done`, `failed`) and,
  when done, fresh results.
- Broadcast on `Phoenix.PubSub` when a seek job finishes, so a later
  WebSocket or SSE endpoint can push updates. (The push endpoint itself can be
  a follow-up task.)
- Handle Oban uniqueness: several searches can share one seek job.

## Acceptance criteria

- Tests cover pending → done, a failed job, and two searches that share a job.
