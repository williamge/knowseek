# 019. Web UI follow-ups

- Status: open
- Area: `frontend/`
- Depends on: 006, 008, 013

## Goal

Replace the stand-ins in the first web UI.

## Scope

- Task 006 done: replace the polling in `frontend/src/lib/useSearch.ts` with the search status endpoint or push.
- Task 008 done: show the written answer above the results, with citations that link to documents.
- Task 013 done: generate `frontend/src/types.ts` from the OpenAPI spec.
- Topics: show new documents per topic, edit the interval, pause a topic (needs an API change for `active`).
- Search options: a freshness control that sends `max_age_seconds`.
- Task 014 done: remove the client-side grouping in `groupHits`.
