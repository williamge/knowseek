# 028. Live facts for entities

- Status: done
- Area: product design + `Knowseek.Lookup`/`Knowseek.Discovery`
- Depends on: none

This was a design session with the owner, not an implementation task. It wrote
no code. Its decisions are recorded in
[ADR 0017](../decisions/0017-live-fact-cards.md).

## Goal

When a query is about an entity with live state (example: "knicks"), Knowseek
should show current facts (is there a game on, the score, the next or last
game) next to the indexed results, and keep them fresh while the user looks.

## Context

The index holds text documents (chunks and embeddings). Live facts are small
structured state with a validity window of seconds. They do not belong in
`documents`/`chunks`. Nothing here runs when nobody is looking, which is the
opposite of the removed topic cron (see "What the removed version did" in
[027](027-rethink-topics.md)).

## What we verified

Manual probes on 2026-10-31 (UTC). Sources can change; re-check before relying
on them. Run from one developer machine with `curl` and `jq`.

- **Wikidata search** (`wbsearchentities`, `language=en`):
  - `nvda` returns "NonVisual Desktop Access" (Q1116614, a screen reader)
    first, and Nvidia (Q182477) second. A ticker does not reliably resolve to
    the company by search alone.
  - `nvidia` returns Nvidia (Q182477) first.
  - `tokyo` returns Tokyo (Q1490, "capital and largest city of Japan") first.
    The second hit is the special wards (Q7473516), the third is Sony Group.
  - `weather in tokyo` returns no results. So the query must be split into an
    intent ("weather") and a place ("tokyo") before resolving. This is a design
    point: entity resolution takes a query that may contain an intent word.
  - `knicks` returns Q131364 "New York Knicks" first (instance of Q13393265
    "basketball team", league P118 = Q155223 NBA). It has 74 sitelinks and 49
    claims, and no ESPN or NBA team id property.
- **Wikidata `wbgetentities`**:
  - Nvidia (Q182477, 82 sitelinks) has no top-level P249 claim. The ticker is a
    *qualifier*: `stock exchange` (P414) = Q82059 (Nasdaq) carries the
    qualifier `ticker symbol` (P249) = "NVDA". The mapping reads P414 with its
    P249 qualifier. `instance of` is Q891723 (public company) and Q4830453
    (business). The Yahoo symbol for a US listing is the ticker; other
    exchanges need a suffix, which was not probed.
  - Tokyo (Q1490) has `coordinate location` (P625): latitude 35.68944,
    longitude 139.69167.
- **ESPN teams list**
  (`.../basketball/nba/teams`): 30 teams, each with `id`, `abbreviation`
  (Knicks: id 18, slug `ny`), and `displayName`. Matching the Wikidata label
  against `displayName` (Wikidata items with league NBA and instance of
  basketball team, via one SPARQL query): 29 of 30 match exactly. The one
  mismatch is "LA Clippers" on ESPN against "Los Angeles Clippers" on Wikidata.
  "Denver Nuggets" appears twice in Wikidata with the same label. The query
  also returns historical franchises (for example "Baltimore Bullets"). So the
  step needs an alias for the Clippers and a tie-break for duplicates, and must
  fail soft for an unmatched team. A first attempt that searched Wikidata once
  per team hit its rate limit ("too many requests"); the SPARQL result above
  replaces it. Wikidata rate limits are real, so resolution needs a cache.
- **ESPN status fields**: `status.type.name` and `status.type.state`
  distinguish the cases: `STATUS_SCHEDULED` with `state: pre`,
  `STATUS_IN_PROGRESS` with `state: in`, `STATUS_FINAL` with `state: post` and
  `completed: true`. In-progress events also carry `clock`, `displayClock` and
  `period`. Seen on the Knicks schedule (scheduled, final) and the NBA
  scoreboard (in progress, final). Other names such as postponed were not seen.
- **ESPN cache headers**: the scoreboard answered `cache-control: max-age=3`.
  No `etag`, `last-modified` or `expires` header was returned. So the upstream
  itself refreshes on a seconds scale; our TTL floor should not be below that.
  Only the scoreboard was checked for headers.
- **ESPN other endpoints** (from an earlier probe the same day): `/teams/ny`
  (record 2-4, `nextEvent` Brooklyn Nets at New York Knicks 2026-11-03T00:30Z),
  `/teams/ny/schedule` (completed events with scores), `/teams/ny/roster`
  (athletes with injuries, Jose Alvarado "Out"), `/summary?event=<id>` (final
  98-93 PHI, leaders, AP recap), `/news?team=18` (headlines and short
  descriptions). All without a key. The API is undocumented; terms and
  stability are unknown.
- **Open-Meteo forecast**
  (`/v1/forecast?latitude=35.689&longitude=139.692&current=temperature_2m,weather_code&temperature_unit=fahrenheit`):
  returned `time`, `interval` 900 (15 minutes), `temperature_2m` 71.0 and
  `weather_code` 0, with no key. The free tier is for non-commercial use.
- **Open-Meteo geocoding** (`geocoding-api.open-meteo.com/v1/search?name=Tokyo`):
  returns candidates with `latitude`, `longitude`, `timezone`, `country` and
  `population`. First: Tokyo, Japan, 35.6895, 139.69171, `Asia/Tokyo`. Second:
  Tokyo, Papua New Guinea. The first matches Wikidata P625 to 3 decimals. It
  also returns the IANA timezone, which Wikidata coordinates do not give.
  Searching `weather in tokyo` returns no results, as on Wikidata.
- **Yahoo-style chart endpoint**
  (`query1.finance.yahoo.com/v8/finance/chart/NVDA?range=1d&interval=1d`):
  **this probe failed.** Both with and without a browser `User-Agent`, and on
  `query1` and `query2`, repeated calls over several minutes returned HTTP 429
  "Too Many Requests" with a plain-text body. So the response without a
  User-Agent is a 429, but that cannot be told apart from the rate limit, and
  the field list (previous close, market state, timestamps) is **unverified**.
  An earlier probe (same day, with a browser User-Agent) returned
  `meta.regularMarketPrice`. Task [032](032-company-card.md) must re-probe
  before relying on any other field.
- NYT RSS (`rss.nytimes.com/services/xml/rss/nyt/Sports.xml`) returns
  headlines only.
- Not usable: `cdn.nba.com` live JSON did not return JSON to plain curl
  (not diagnosed); a TheSportsDB probe failed to parse; the Stooq URL tried
  returned an error page.
- Prediction markets, inconclusive: Kalshi's first 200 open markets had no
  Knicks or Nvidia market; Polymarket public search returned only past Knicks
  series (not filtered for open).

## Decisions

All in [ADR 0017](../decisions/0017-live-fact-cards.md):

1. **Product shape.** A card of structured facts above the ranked results.
   Cards are facts; results are context. Cards are never stored as documents.
2. **Identity.** Wikidata resolves a query to an entity; `instance of` routes to
   a card provider. Ambiguity: show the top entity's card and list the
   alternatives. Alternatives to Wikidata stay open to explore later.
3. **Three first providers**, each behind a swappable source behaviour:
   sports team (ESPN), public company (Yahoo-style chart), place and weather
   (Open-Meteo). Bare "weather" uses the browser location as context.
4. **Refresh model.** A separate endpoint that is cache-only: it never calls a
   provider in the request path. A supervised in-process refresher fills the
   cache with single-flight per entity, a short timeout and a backoff. The
   response carries `status` (`fresh | stale | pending | unavailable`) and
   `as_of`. The UI polls (fast while `pending`, then at the state-dependent TTL
   cadence). No cron, no Oban job, no table. Push (WebSocket/SSE) is deferred.
5. **Architecture rule 6** is amended: the request path never calls an external
   provider, except the existing query embedding in `Search`. Card and entity
   cache refreshes run in supervised in-process tasks, not Oban, because they
   are disposable. Writes to the index still go through Oban.

## Still open

Deferred on purpose. Do not design these without the owner:

- "Context sources" for the results list: newspapers and wires (NYT, Reuters;
  no scores as data, paywalled), Reddit and other social, official team and
  league sources.
- Prediction markets (Polymarket, Kalshi) and sportsbook odds as a card
  extension.
- What "following" should be (absorbs the questions of task
  [027](027-rethink-topics.md)).
- General web and news search (tasks [003](003-web-search-source.md) and
  [004](004-feed-source.md) stay parked).
- How fresh and stale Wikipedia content is shown. Wikipedia text is current
  within days (the indexed Knicks article was edited the day before the probe),
  but it does not carry yesterday's game: game logs are tables, and plain-text
  extracts drop tables. That is why live facts come from cards. The search
  returned the 2025-26 season page rather than the current 2026-27 one, which
  is a relevance matter, not freshness. Task 038 shows the source's last-edit
  date on hit cards.
- Passage selection. The best passage for the main Knicks article was about the
  1967-68 season.
- WebSocket or SSE push for cards (revisit with many viewers and updates faster than 5 s).
- Whether the ranking prior of task [035](035-ranking-prior.md) is wanted at
  all, and when.

## Outcome

Design done; no code written. Decisions are in ADR 0017. Implementation is
split into:

- [030](030-entity-resolution.md) entity resolution via Wikidata
- [031](031-card-framework-sports.md) card framework and sports-team card
- [032](032-company-card.md) company card
- [033](033-weather-card.md) weather card
- [034](034-weather-location-context.md) bare "weather" location context
- [035](035-ranking-prior.md) ranking prior from document importance (open;
  the owner has not decided its priority)

Relationship to other tasks: a polling card can reuse the discovery-completion
signal of task [006](006-discovery-status-for-callers.md); the intent-splitting
of task [007](007-query-planning.md) overlaps task 030 (see the notes there).

## Out of scope

News search and general web coverage (tasks [003](003-web-search-source.md),
[004](004-feed-source.md)); users (task [009](009-users-and-api-keys.md)).
