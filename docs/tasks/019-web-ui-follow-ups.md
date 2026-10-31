# 019. Web UI follow-ups

- Status: open
- Area: `frontend/`
- Depends on: 006, 008, 013, 024

## Goal

Replace the stand-ins in the first web UI.

## Scope

- Task 006 done: replace the polling in `frontend/src/lib/useSearch.ts` with the search status endpoint or push (see task 021).
- Task 008 done: show the written answer above the results, with citations that link to documents.
- Task 013 done: generate `frontend/src/types.ts` from the OpenAPI spec.
- Topics: show new documents per topic, edit the interval, pause a topic (the API for editing and pausing is task 024).
- Search options: a freshness control that sends `max_age_seconds`.
- Task 014 changed `groupHits` in `frontend/src/lib/format.ts`: it no longer groups anything, it maps each hit and its `passages` to a card. Fold it into the card component or rename it.
