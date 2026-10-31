# 0017. Live fact cards for entity queries

- Status: Accepted
- Date: 2026-10-31

Related: [0015](0015-remove-topics.md) (removed the cron-refreshed topics),
task [028](../tasks/028-live-facts-for-entities.md) (the design session).

## Context

Knowseek indexes text documents. A query like "knicks" returns ranked Wikipedia
passages, one of them a season old and another about the 1967-68 season. It
does not say whether the Knicks play tonight, or what the score is. Those are
small structured facts with a validity window of seconds to minutes. They are
not text, and storing them as documents would make the index wrong within
minutes.

The ADR 0015 topics feature refreshed a query on a cron whether or not anyone
looked at it. It was removed.

## Decision

### 1. Product shape

A query about an entity with live state gets a **card** above the normal ranked
**results** list. A card is a small box of structured facts from an API,
fetched fresh and never stored as documents or chunks. The results are the
indexed text documents, which is what Knowseek already does. Cards are facts;
results are context.

Example page for "knicks": the card (last game L 93-98 at PHI, record 2-4, next
game vs BKN, injuries), then the ranked documents.

### 2. Identity

Wikidata is the entity-resolution source: query to Wikidata item (id, label,
description, `instance of` type, sitelink count, Wikipedia title). The
`instance of` type routes to a card provider by entity type. Alternatives to
Wikidata stay open to explore later (for example an LLM intent step from task
[007](../tasks/007-query-planning.md)); Wikidata goes first.

Ambiguity: show the top entity's card and list the alternatives (for example
"also: Westchester Knicks") instead of letting them compete in the ranking.

Probes (task 028) show a query may carry an intent word: `weather in tokyo`
returns nothing from Wikidata, so the query is split into intent and place
before resolving. A ticker does not reliably resolve by search (`nvda` returns
a screen reader first).

### 3. Three first card providers

Each sits behind a swappable source behaviour with its module chosen by config
(architecture rule 4):

- **Sports team** ("knicks"): ESPN's public site API. Undocumented, no key.
- **Public company** ("nvda"): a Yahoo-style chart endpoint. Unofficial, needs
  a browser User-Agent, and was rate limited (HTTP 429) in the verification
  probes. A keyed provider such as Finnhub or Alpha Vantage is the documented
  fallback.
- **Place and weather** ("weather in tokyo"): Open-Meteo. No key; the free tier
  is non-commercial.

Bare "weather" with no place later uses the browser's geolocation (with a
permission prompt and a saved-home-city fallback) as context, not as an entity.

### 4. Refresh model: a cache-only endpoint and a background refresher

- The UI gets the card from a separate small endpoint, not an extra field on
  `POST /api/search`.
- The endpoint is **cache-only**. A `GET` reads an in-memory cache (ETS or
  equivalent) and never calls an external provider in the request path. The
  response always carries `status` (`fresh`, `stale`, `pending`, or
  `unavailable`), `as_of`, and the card data when there is any. Stale data is
  returned with status `stale`.
- If the entry is missing or past its TTL, the endpoint asks a **refresher** to
  start a refresh and returns at once: `pending` when nothing is cached,
  `stale` when something is.
- The refresher is a supervised in-process component (a `Task.Supervisor` plus
  a registry or a single GenServer per key). It gives **single-flight** per
  entity: many viewers cost one upstream call. The upstream call has a short
  timeout. A failure keeps the old value (`stale`, or `unavailable` if nothing
  ever succeeded) and applies a short backoff, so a down upstream is not
  hammered.
- The TTL depends on state: a live game 10-30 seconds, a scheduled game until
  tip-off, a final game hours; prices and weather a few minutes.
- The UI polls: fast (about 0.5-1 s) while `pending`, then at the TTL cadence.
  It shows an "as of <time>" stamp and says so when the card is stale.
- Nothing runs when nobody is looking: no cron. The cache is disposable. A
  restart loses it and the next poll refills it. There is no Oban job, no
  table, and no migration.
- Entity resolution (task 030) follows the same pattern with a long TTL,
  because entities rarely change. A cold query pays a latency cost; task 030
  says how it behaves.
- WebSocket or SSE push is **not adopted**. It is a deferred alternative:
  revisit it if many viewers and updates faster than 5 seconds are needed. The
  `status` and `as_of` contract lets push replace polling later without
  changing the card shape.

### 5. The architecture rule tension and the amendment

Rule 6 said slow or external work runs in Oban jobs and the request path may
only enqueue. Rule 5 says no external calls inside a transaction. A card needs
an external API call because its data is live.

The request path of a card never calls the provider (decision 4), so the card
endpoint itself follows the spirit of rule 6. The honest exception is elsewhere:
`Knowseek.Search.search/2` already embeds the query through the embeddings
adapter in the request path and returns HTTP 503 when the provider fails
(ADR 0016). Rule 6 is amended to say so:

> The request path never calls an external provider, with one existing
> exception: query embedding in `Search`. Everything that writes to the index
> runs in Oban jobs. Card and entity cache refreshes run in supervised
> in-process tasks instead, because they are disposable: their retry is the
> next poll, and an Oban row per refresh interval per viewed entity would be
> churn.

Rule 5 is untouched: no database connection or transaction is held during a
refresh. Rules 2 and 3 are untouched: cards never go through
`Documents.ingest/1`, and card providers never write to the database. The
amendment is in `AGENTS.md` and `docs/ARCHITECTURE.md`. Entity resolution and
the cache behind it (`Knowseek.Entities`, `Knowseek.Cache`, task 030) are
built; the card framework (tasks 031-034) is decided design, not shipped code.

## Consequences

- A new public context for entity resolution (task 030) and one for cards (task
  031), each with a source behaviour and config.
- The frontend gets a card component and types mirrored in `types.ts`.
- Cards depend on unofficial or free-tier upstreams. They can break or
  disappear without notice; the failure mode is a stale or absent card, never a
  failed search.
- Wikidata is rate limited (the probes hit it), so resolution results are
  cached.
- Mapping an entity to a provider needs our own step: Wikidata has no ESPN id
  for a team (match the label against ESPN's team list, with an alias for "LA
  Clippers"), and the ticker of a company is a qualifier on its stock exchange
  claim, not a claim of its own.

## Deferred (explicitly not decided)

- "Context sources" for the results list: newspapers and wires (NYT, Reuters),
  which do not provide scores as data and are paywalled; Reddit and other
  social; official team and league sources.
- Prediction markets (Polymarket, Kalshi; probes inconclusive) and sportsbook
  odds as a card extension.
- What "following" should be (absorbs the questions of task 027).
- General web and news search (tasks 003 and 004 stay parked).
- How fresh and stale Wikipedia content is shown: the indexed Knicks article is
  a season old although labelled "fetched just now". Freshness of fetch is not
  recency of content.
- Passage selection: the best passage for the main Knicks article was about the
  1967-68 season.
- The ranking prior (document importance from Wikipedia pageviews or Wikidata
  sitelinks) is a proposed standalone task, [035](../tasks/035-ranking-prior.md).
  The owner has not decided its priority.

## Alternatives rejected

- **Facts as documents in the index.** They would be stale within minutes and
  would compete with text in ranking, which has no notion of recency.
- **Cron-refreshed facts**, like the topics removed in ADR 0015. They do work
  when nobody looks, and need a user or a follow concept that does not exist.
- **A card field on `POST /api/search`.** It couples a seconds-scale refresh to
  a heavy search call and makes the card uncacheable on its own.
- **Scraping newspaper score pages.** Paywalled, fragile, and not data.
- **Inline fetch with a timeout in the request path.** Simpler, but a cold
  request blocks on an external API, and it needs a wider rule 6 exception.
- **An Oban job, result storage, and polling.** Durability is worthless for a
  disposable cache, and one job row per refresh interval per viewed entity is
  churn.
- **WebSocket or SSE push.** Deferred, not rejected (see decision 4).
