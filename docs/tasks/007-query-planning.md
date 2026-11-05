# 007. LLM query planning for sources

- Status: done ([ADR 0025](../decisions/0025-query-planning.md))
- Area: `Knowseek.Discovery`
- Depends on: 002 or 003 (needs at least one real source)

Note: for entity queries its job (turning a query into something searchable) overlaps entity resolution in [028](028-live-facts-for-entities.md). Decide after 028 whether 007 is still needed and for what.

Note: [ADR 0017](../decisions/0017-live-fact-cards.md) chose Wikidata for entity identity and a plain intent/place splitter (task [030](030-entity-resolution.md)). An LLM intent step stays an open alternative.

## Goal

A user query like "what's new in battery chemistry for EVs" is a poor
literal search string. Use an LLM to turn it into a few focused search
queries before discovery calls the sources.

The LLM is local, through Ollama (the same server as the embeddings), so no
API key is needed. A hosted adapter (Anthropic or another) can be added later
behind the same behaviour.

## Scope

- A `Knowseek.Discovery.Planner` behaviour with an Ollama implementation (a
  small local chat model, using `Req` and Ollama's structured output) and a
  pass-through implementation for tests and as the default until the owner
  opts in.
- Use structured output (a JSON schema in the chat request) so the plan is
  parseable.
- `Discovery.run/2` calls the planner, then each source with each planned query.
- Cap the number of planned queries and log the plan.

## Acceptance criteria

- Tests with `Req.Test` stubs. No network.
- An ADR records the model and the prompt location.

## Outcome

Built, as [ADR 0025](../decisions/0025-query-planning.md) records:

- `Knowseek.Discovery.Planner` (behaviour, and `resolve/2` that enforces the
  safety rules for every adapter), `Planner.Passthrough` (default, pinned in
  tests), `Planner.Ollama` (`qwen3:1.7b`, chosen by the owner after a trial, `POST /api/chat` with a
  JSON schema, no retries, 15 s timeout). `PLANNER_ADAPTER=ollama|passthrough`
  and `OLLAMA_CHAT_MODEL` in `config/runtime.exs`, `.env.example`, README;
  `scripts/ensure-ollama` pulls and loads the chat model when the planner is
  `ollama`.
- `Discovery.run/2` plans, searches every source with every planned query,
  merges by canonical URL (in rounds, original query first), caps at
  `max_candidates` (12), tolerates a failing query, and returns `plan` and
  `planner` in its summary. Planner failure falls back to the literal query.
  The `SeekWorker` retry rule is unchanged and still correct.
- The model evaluation, the real-Wikipedia comparison, and the product
  observations are in the ADR and the pull request.

Left out (on purpose; options and a recommendation are in the ADR):

- Showing the plan in the UI or the API, feeding planned queries into the
  search itself, and using the plan for cards or entity resolution.
- A hosted (Anthropic) adapter. The behaviour is ready for one.
- Making Ollama the default planner (the owner opts in with
  `PLANNER_ADAPTER=ollama`; the model is `qwen3:1.7b`, Apache-2.0, chosen by
  the owner on 2026-11-05).
- `docker-compose.yml` does not forward `PLANNER_ADAPTER` and
  `OLLAMA_CHAT_MODEL` to the app container.

Added after the review of PR #42: a 5 minute job timeout,
`Source.discover_many/2` (each distinct Wikipedia page fetched once), the
planner playground (dev only: `/planner`, `/api/planner/*`) to try other
models, and the `think: false` option for models that think by default.

Follow-up: [046](046-query-planning-follow-ups.md).
