# 0008. Web frontend in Vite, React, and TypeScript

- Status: Accepted
- Date: 2026-10-30

## Context

Knowseek needs a web page to search and to manage topics. ADR 0001 made the
backend API only (no HTML, no LiveView, no assets). Rule 8 in `AGENTS.md` keeps
non-Elixir parts behind HTTP.

## Decision

Build the UI as a separate single-page app in `frontend/`, with Vite, React, and
TypeScript. It uses only the public JSON API. In development, Vite proxies `/api`
to the Phoenix API, so no CORS configuration is needed.

The UI keeps its state in the URL, so a search is a link.

Discovery runs in the background and the API cannot report when it finishes
(task 006). The UI polls `GET /api/documents` after a search that enqueued
discovery, and searches again when new documents appear. This is a stand-in.
Task 006 replaces it with a status endpoint or push.

## Consequences

- The backend stays API only. UI work and backend work do not conflict.
- The UI has no production serving story yet. See `docs/tasks/018-serve-frontend-in-production.md`.
- Polling adds a small amount of load, and each re-search can enqueue discovery again (deduplicated by Oban only while the earlier job for the same query is still queued, running or retrying; a repeat after it completes enqueues again, and is cheap because unchanged bodies are not re-embedded; corrected 2026-11-01).
- `frontend/src/types.ts` duplicates the API shapes by hand until task 013 (OpenAPI) generates them.
