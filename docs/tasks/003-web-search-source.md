# 003. Web search discovery source

- Status: open
- Area: `Knowseek.Discovery`
- Depends on: none

Note: parked until the owner wants general web/news coverage. The owner does not want news search now and prefers entity-specific sources first (see [028](028-live-facts-for-entities.md)).

Note: what newspapers, wires, social and official sources should be for the results list is a deferred open question in [ADR 0017](../decisions/0017-live-fact-cards.md) and [028](028-live-facts-for-entities.md). The task stays parked.

## Goal

Find new data on the open web for queries that Wikipedia does not cover.

## Scope

- Pick a web search API (for example Brave Search, Tavily, or Exa). Write an
  ADR with the reasons (cost, terms, whether it returns page content).
- `Knowseek.Discovery.Sources.WebSearch` that searches and returns candidates.
- If the API does not return page text: fetch each page and extract the main
  text. Start simple (Floki, drop nav/script/style). If extraction quality is
  poor, write a follow-up task for an extraction service in `services/`.
- Respect `robots.txt` for page fetches, set a timeout, and cap the size.
- API key from the environment. The source is skipped (with a log line) when
  the key is missing.

## Acceptance criteria

- Tests use `Req.Test` stubs. No network.
- Extraction has tests with small HTML fixtures.
