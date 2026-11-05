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
