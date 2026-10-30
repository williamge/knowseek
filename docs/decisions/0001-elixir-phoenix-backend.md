# 0001. Elixir + Phoenix for the backend

- Status: Accepted
- Date: 2026-10-30

## Context

The service does a lot of concurrent, I/O-bound work: serving searches, calling
external sources, and running scheduled refreshes. We want supervision and
background jobs without a separate job runner.

## Decision

Write the backend in Elixir with Phoenix (API only: no HTML, no LiveView, no
assets). Use Oban for background jobs. The backend lives in `backend/`.

Other languages are allowed for background services in `services/` when they
have a clear advantage (for example Python for content extraction or ML). See
`services/README.md` for the rules.

## Consequences

- One runtime handles the API, jobs, and scheduling.
- Some ML and scraping libraries are stronger in Python. Those can become
  separate services with an HTTP or job contract.
