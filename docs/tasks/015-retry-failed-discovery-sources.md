# 015. Retry failed discovery sources

- Status: open
- Area: `Knowseek.Discovery`
- Depends on: none

## Goal

When a source fails with a temporary error, try it again later. Today the
failure is logged and lost.

## Context

`Discovery.run/2` logs a source's `{:error, reason}`, uses `[]` for that
source, and always returns `{:ok, summary}`. `SeekWorker` has
`max_attempts: 3`, but it never retries, because the job always succeeds.
The `SeekWorker` uniqueness covers only incomplete jobs, so after a failed
run nothing seeks the query again until a user repeats it or a topic
refresh requests it.

Found in the review of task 002 (PR #2). With the Wikipedia source, a short
outage or a `maxlag` refusal means the query gets no data.

Ingest has the same problem. Since task 001, `Documents.ingest/1` can return
`{:error, {:ollama | :voyage, ...}}` when the embedding provider is down
(Ollama stopped, Voyage 5xx after its own retries). `Discovery.run/2` counts
these as `failed`, still returns `{:ok, summary}`, and the job completes.
The fetched candidates are lost. Found in the review of task 001 (PR #4).

## Scope

- Let `run/2` report which sources failed (for example `failed_sources` in
  the summary).
- When a source fails, make the job retry only that source. Do not run the
  successful sources again. Options: snooze the job with the failed sources
  in its args, or enqueue a new job per failed source. Pick one and explain
  why in the Outcome.
- Separate temporary errors (timeouts, 429, 5xx, `maxlag`) from permanent
  ones (other 4xx, bad responses). Retry only temporary errors. This may need
  a small change to the `Source` behaviour contract, for example
  `{:error, {:temporary, reason}}`. If you change the contract, write an ADR
  and update every source.
- Back off between attempts (Oban `backoff/1`).
- Treat a temporary ingest error (`{:ollama | :voyage, 5xx | transport}`) like
  a temporary source error. Retry only the candidates that failed to ingest.
  Do not call the sources again. Pass the candidates in the retry job args, or
  fetch them again if they are too large. Explain the choice in the Outcome.

## Acceptance criteria

- Tests: a source that fails with a temporary error is retried, and a source
  that succeeded is not called again.
- Tests: a permanent error is not retried.
- Tests: a candidate that fails to ingest with a temporary embedding error is
  retried, and the sources are not called again.
- `docs/ARCHITECTURE.md` describes the retry behaviour.
