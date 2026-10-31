# 030. Entity resolution via Wikidata

- Status: open
- Area: new public context `Knowseek.Entities`
- Depends on: none

## Goal

Turn a search query into an entity (and alternatives) that a card provider can
use. Decided in [ADR 0017](../decisions/0017-live-fact-cards.md); probes in
[028](028-live-facts-for-entities.md). Wikidata first; other resolvers stay
possible behind the same behaviour.

## Scope

- Public API in `Knowseek.Entities`: `resolve(query, opts)` returns
  `{:pending, query}` on a cold cache, `{:ok, %{intent: atom | nil, entity: entity, alternatives: [entity]}}` or
  `:none` when nothing useful matches, or `{:error, reason}`. An entity has
  `id` (Wikidata Q-id), `label`, `description`, `types` (`instance of` ids),
  `sitelinks` (count), `wikipedia_title`, and the raw claims a provider needs
  (`coordinates` from P625, `exchange_tickers` from P414 with its P249
  qualifier).
- A resolver behaviour with the Wikidata module chosen by config (rule 4):
  `wbsearchentities` for candidates, `wbgetentities` for details. Requests send
  a descriptive User-Agent. Configure `base_url`, `user_agent`, `req_options`.
- Intent/place splitting: `weather in tokyo` returns nothing from Wikidata, so a
  small deterministic splitter recognises the `weather in <place>` and
  `<place> weather` shapes and resolves only the place; it returns
  `intent: :weather`. Anything else resolves whole. The splitter is plain code,
  not an LLM (task [007](007-query-planning.md) may replace it later).
- Choosing the top entity: the first search hit that has a type a provider
  handles; the other hits with the same kind of type become `alternatives`
  (for example Westchester Knicks). A ticker query (`nvda`) puts a screen
  reader first, so candidates are filtered by supported type, not taken
  blindly.
- Cache-only with a background refresh, like the cards (ADR 0017, decision 4), with a long TTL (hours to days; entities rarely change). A cold query is `{:pending, _}`: `resolve/2` returns at once and starts one single-flight Wikidata fetch; the UI polls the entity status until it is ready, then the card. Cold-start latency (the Wikidata calls plus the first card fetch) is the accepted cost. Cache successful and empty responses;
  Wikidata rate limits requests ("too many requests" seen in probes).
- Failure behavior: timeout or HTTP error returns `{:error, reason}`; search
  must keep working without an entity. Nothing writes to the database.

## Acceptance criteria

- Tests use `Req.Test` stubs with Wikidata fixtures added to
  `backend/test/support/fixtures.ex`; no test hits the network.
- `knicks` resolves to Q131364 with alternatives listed; `weather in tokyo`
  gives `intent: :weather` and the Tokyo entity (Q1490) with coordinates;
  `nvidia` resolves with exchange ticker NVDA from the P414/P249 qualifier; a
  query with no match returns `:none`.
- A cold call returns `{:pending, _}` without calling the stub itself; a later call returns the entity; a second identical call makes no new stub call; a 429 or
  timeout returns `{:error, _}`.
- Every new public function has a test.

## Out of scope

Card providers (tasks [031](031-card-framework-sports.md) onward), LLM intent
detection, any HTTP endpoint.
