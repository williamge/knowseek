# 046. Query planning follow-ups

- Status: open
- Area: `Knowseek.Discovery`, `Knowseek.Lookup`, `docker-compose.yml`, `frontend/`
- Depends on: 007

## Goal

Task [007](007-query-planning.md) ([ADR 0025](../decisions/0025-query-planning.md))
plans queries inside the discovery job and does nothing else with the plan.
Decide, with the owner, which of the options below to build. Each is
independent. The ADR has the evidence and the recommendation.

## Scope

- **Compose.** `docker-compose.yml` does not forward `PLANNER_ADAPTER` or
  `OLLAMA_CHAT_MODEL`, so the app container never plans. Forward both (with
  empty defaults, like `OLLAMA_MODEL`) and say in the README that a container
  reaches the host's Ollama through `APP_OLLAMA_URL`.
- **Choose the model.** The model is open (ADR 0025): `qwen2.5:3b` is the
  model of the evaluation and is under a non-commercial research licence. The
  owner tries candidates in the planner playground (`/planner`, dev only),
  then the ADR records the model, its licence and the default, and
  `PLANNER_ADAPTER=ollama` can become the default.
- **Job cost.** A planned job is up to 4 searches and 12 page fetches, one at a
  time (16 Wikipedia calls at 15 s each in the worst case; `discover_many/2`
  fetches each distinct page once, but disjoint pages still cost one fetch
  each). The job has a 5 minute timeout. Options: fetch pages concurrently
  with a small limit, or fetch only the pages that survive the
  `max_candidates` cap, or lower `max_candidates`.
- **Partial ingest failures.** `SeekWorker` retries only when every candidate
  failed to ingest. With up to 12 candidates, 11 failures and 1 success is
  `:ok` and the 11 are not retried. Ingest does not re-embed unchanged
  documents, so retrying when some failed is cheap; a permanently bad
  candidate would retry for nothing (3 attempts).
- **Planning concurrency.** Up to 5 discovery jobs call Ollama at once; a burst
  past the 15 s timeout falls back to the original query, and that fallback is
  not retried. Options: a queue of its own with a lower limit, or a retry of
  a planner timeout.
- **Show the plan.** The plan is only in the log and in the `run/2` summary.
  Options: store it in the Oban job (`meta`) and return it from the discovery
  status of [006](006-discovery-status-for-callers.md); the UI then shows
  "Also searched for: ...".
- **Planned queries in the search itself.** Today discovery only fetches new
  documents; the literal query still ranks the index. Planned queries could be
  embedded and their results fused (reciprocal rank fusion) into the search.
  This touches `Knowseek.Search` and puts an LLM call in the request path, which
  rule 6 forbids, so it needs a cached plan (the job stores it, the next search
  reads it) and a decision.
- **Source language.** Wikipedia is the English edition. A request in French,
  German, or Japanese finds little there; the planner keeps the person's
  language. Options: per-source language in the `Source` behaviour and a
  prompt that translates to it, or a larger model.
- **Cards and entities.** [043](043-smarter-weather-queries.md) and
  [028](028-live-facts-for-entities.md) mention an LLM intent step. The same
  planner call could return an intent and an entity name next to the queries.
- **Answer synthesis.** [008](008-answer-synthesis.md) can reuse
  `Planner.Ollama`'s request shape (schema-constrained chat, untrusted input,
  `Planner.clean/2`) and the configured chat model.

## Acceptance criteria

- Per option that is built: tests with `Req.Test` stubs, docs updated, and the
  ADR (or a new one) records the decision.
