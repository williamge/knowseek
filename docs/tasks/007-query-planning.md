# 007. LLM query planning for sources

- Status: open
- Area: `Knowseek.Discovery`
- Depends on: 002 or 003 (needs at least one real source)

Note: for entity queries its job (turning a query into something searchable) overlaps entity resolution in [028](028-live-facts-for-entities.md). Decide after 028 whether 007 is still needed and for what.

## Goal

A user query like "what's new in battery chemistry for EVs" is a poor
literal search string. Use an LLM to turn it into a few focused search
queries before discovery calls the sources.

## Scope

- A `Knowseek.Discovery.Planner` behaviour with an LLM implementation (Claude
  via the Anthropic Messages API, using `Req`) and a pass-through
  implementation for tests and when no API key is set.
- Use structured output (tool use or JSON) so the plan is parseable.
- `Discovery.run/2` calls the planner, then each source with each planned query.
- Cap the number of planned queries and log the plan.

## Acceptance criteria

- Tests with `Req.Test` stubs. No network.
- An ADR records the model and the prompt location.
