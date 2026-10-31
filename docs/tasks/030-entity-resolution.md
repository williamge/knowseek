# 030. Entity resolution via Wikidata

- Status: done
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

## Outcome

Built:

- `Knowseek.Entities` (`resolve/2`, `await/2`, `choose/1`, `kind/1`), with
  `Entities.Entity`, the `Entities.Resolver` behaviour (`search/2`), the
  `Entities.Wikidata` resolver (`wbsearchentities` + one batched
  `wbgetentities`, descriptive User-Agent, `maxlag`, no retries), and
  `Entities.Intent` (`weather in <place>`, `<place> weather`). Config in
  `config/config.exs` (`resolver`, `ttl` one day, `backoff` one minute,
  `timeout`, `max_alternatives` 5, `max_query_length` 100, `supported_types`).
- `Knowseek.Cache`, the reusable piece that task 031 should use for cards: an
  ETS table plus a supervised fetch task per key. `get(cache, key, fetch_fun,
  ttl: ms | fun, backoff: ms, timeout: ms)` returns `{:fresh | :stale, value,
  as_of}`, `:pending` or `{:unavailable, reason}` and never fetches in the
  caller. Single-flight per key, stale-while-revalidate, the old value kept on
  failure, a backoff, a fetch timeout, `max_entries`, an injectable `clock`.
  Started in the supervision tree as `Knowseek.Entities.Cache`.
- Wikidata fixtures recorded from the live API (2026-10-31) in
  `test/support/fixtures/wikidata/`, and `Knowseek.Fixtures.stub_wikidata/0`,
  `wikidata_fixture/1`, `wikidata_item/1`.

Decisions:

- The supported types are config: a keyword list of kind (`:sports_team`,
  `:company`, `:place`) to `instance of` ids. An entity has a kind when one of
  its types is in the list and it has what the provider needs (company: an
  exchange ticker; place: coordinates). The list is flat, not `subclass of`:
  Tokyo (Q1490) is instance of big city, megacity, global city and metropolis,
  and none of them is Q515 city. Observed ids are in the config comments.
- `Entity` has no `kind` field; `Entities.kind/1` computes it.
- A P414 item with several exchanges (Sony: Tokyo and New York) lists every
  claim that has a P249 qualifier, as `%{exchange: "Q217475", ticker: "6758"}`.
  Deprecated claims and claims with an end time (P582) are skipped.
- The label and description come from the search hit. `wbgetentities` with
  `languages=en` returns no `en` label for some items (the screen reader
  Q1116614 has none), so they are not read from the details.
- The cache key is the lowercased text after the intent split, so `Knicks`,
  `knicks` and `weather in knicks` share an entry.
- `Entities.await/2` blocks until an in-flight fetch ends. It exists for tests
  and scripts; the request path never calls it.

Verified against the real Wikidata with a throwaway script (not committed):
`knicks` gave Q131364 with the alternative Q15927936 (Westchester Knicks);
`nvda` and `nvidia` gave Q182477 with ticker NVDA on Q82059 (the screen reader
of `nvda` was skipped); `weather in tokyo` gave `intent: :weather` and Q1490
with coordinates 35.689, 139.692 and the alternative Q7473516. A cold fetch
took 0.4 to 0.9 s.

Left out:

- No HTTP endpoint and no entity status for the UI (out of scope; task 031's
  card endpoint can expose it).
- No global limit on concurrent Wikidata calls. Backoff is per key, so many
  different cold queries can each call Wikidata once. A cap on in-flight
  fetches in `Knowseek.Cache` would fix it.
- `<place>, <country>` (`tokyo, japan`) and other intent words are not
  recognised.

Follow-ups (no files written):

- Task 031 should build on `Knowseek.Cache` instead of a second cache, and
  add `Knowseek.Cache` start-up for cards to the supervision tree.
- `search_limit` is 20 and the Westchester Knicks are the 20th hit for
  `knicks`: alternatives deeper than that are not found. Ordering
  alternatives by sitelink count may be better than search order.
- Expand types through `subclass of` (SPARQL or a cached class tree) if the
  flat list needs too much upkeep.
- ESPN/Yahoo mapping from `exchange` ids to suffixes (task 032).

Review fixes and limits:

- Ended exchange listings are detected by P582 (end time), not P576 (which is
  "dissolved, abolished or demolished"). Apple (Q312) keeps a Tokyo Stock
  Exchange claim (6689) with P580 and P582 (2004) at normal rank; it is a
  fixture (`search_apple`, `entities_apple`) and a test. The deprecated-rank
  case is only synthetic; no real deprecated claim was found.
- `Knowseek.Cache`: a TTL that is not a number of at least 0 (or a TTL
  function that returns one, or raises) fails that fetch with
  `{:bad_ttl, value}` and keeps the old value; eviction orders by a write
  counter, not the clock, and never drops a key being fetched; `await/3`
  waits `:infinity` by default, because the fetch has its own timeout; a
  table that exists before `init/1` stores the clock reads as not running.
- Probe (live): Texas Q1439 is instance of Q35657 (U.S. state); Japan Q17 of
  Q3624078 (sovereign state), Q112099 (island country), Q6256 (country);
  Paris Q90 of big city, metropolis, global city and others already listed.
  All have P625, so the state and country ids are in `supported_types` and
  `weather in texas` and `weather in japan` resolve (fixtures, tests). The
  coordinates are one point for the whole area.
- Limits: `knicks weather` returns `intent: :weather` with a sports team, so a
  consumer checks `Entities.kind/1` (a weather card needs `:place`).
  `weather in tokyo and osaka` looks up `tokyo and osaka`.
- Fixtures: sitelinks are trimmed to the real `enwiki` entry plus empty
  placeholders that keep the real count; the new searches keep their first 8
  hits.
- Before any endpoint exposes entity resolution, a cap on in-flight fetches
  and a cache-wide 429/maxlag backoff are needed; it is a scope bullet of task
  031.
