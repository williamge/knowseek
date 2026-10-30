# 021. Reliable discovery completion in the web UI

- Status: open
- Area: `frontend/src/lib/useSearch.ts`, `Knowseek.Lookup`
- Depends on: 006

## Goal

The web UI infers that discovery finished from "a new document id appeared in
`GET /api/documents`". This has gaps. Replace it with a real signal.

## Known gaps

- Discovery that only updates existing URLs (a changed body, or a new
  `fetched_at`) adds no new id. The page shows "Looking for new sources" for
  90 seconds and never searches again.
- The watcher stops when coverage becomes `sufficient`. If discovery ingests
  documents one after the other, the later ones do not show until the user
  searches again.
- Each re-search from the watcher calls `Lookup.run`. It embeds the query
  again and tries to enqueue discovery. Oban uniqueness (one hour) hides the
  extra jobs, but the work is not free.

## Scope

- Use the status endpoint or push from task 006 to know when the seek job is
  done. Remove the polling of `GET /api/documents`.
- Give the UI a search that has no side effects: it does not enqueue
  discovery. For example `POST /api/search` with `"discover": false`, or the
  results of `GET /api/searches/:id`.
- After the job finishes, run one search and mark the new results.

## Acceptance criteria

- A test covers a job that only updates existing documents.
- A test shows that re-searching from the UI does not enqueue a job.
