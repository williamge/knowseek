# 006. Tell callers when discovery finishes

- Status: open
- Area: `Knowseek.Lookup`, `Knowseek.Discovery`, web (`frontend/src/lib/useSearch.ts`)
- Depends on: none

Note: a view-time card may reuse the completion signal of this task (see [028](028-live-facts-for-entities.md), [ADR 0017](../decisions/0017-live-fact-cards.md)).

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
- Web UI (absorbed from task 021): replace the inference "a new document id appeared in `GET /api/documents`" in `frontend/src/lib/useSearch.ts` with this signal, and remove the `GET /api/documents` polling. This fixes three gaps: discovery that only updates existing URLs adds no new id (the page waits 90 s and never searches again); the watcher stops at `sufficient` coverage so later ingested documents do not show; each watcher re-search calls `Lookup.run`, which re-embeds the query and tries to enqueue discovery.
- Give the UI a search with no side effects (no discovery enqueue), for example `"discover": false` on `POST /api/search` or the results of `GET /api/searches/:id`. After the job finishes, run one such search and mark the new results.

## Acceptance criteria

- Tests cover pending → done, a failed job, and two searches that share a job.
- A test covers a job that only updates existing documents (UI still gets the finish signal).
- A test shows that re-searching from the UI does not enqueue a job.
