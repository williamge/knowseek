# 039. Rate-limit anonymous endpoints

- Status: open
- Area: `KnowseekWeb` plugs, `Knowseek.Cache` fairness
- Depends on: none (per-user limits need [009](009-users-and-api-keys.md), which is parked)

## Goal

Stop one anonymous client from starving the others on `GET /api/cards` and
`POST /api/search`, and from wearing out the caches and the upstream
allowances behind them.

## Context

There is no authentication yet (task 009), and Knowseek is not meant for the
public internet as it is. The review of task 031 found these limits:

- `GET /api/cards?q=` takes any text as the query. The entity cache caps the
  Wikidata resolutions that run at once (`max_in_flight`, 4) and drops the
  refreshes over the cap. About 10-20 distinct junk queries a second keep all
  slots busy, so a real query stays `pending` and the UI falls back to its slow
  cadence.
- The same junk queries can evict real entries from the entity table (5000
  entries; the oldest are dropped first).
- A Wikidata 429 or `maxlag` blocks all entity resolution, for every client,
  for the `Retry-After` (at most 10 minutes). Cards already cached keep being
  served.
- Drops over the cap are logged (a throttled warning) and counted
  (`Cache.stats/1`), nothing more.
- `POST /api/search` also takes any text, embeds it, and may enqueue discovery
  (see task [016](016-limit-discovery-abuse.md)).

## Scope

- A per-client rate limit on `GET /api/cards` and `POST /api/search`: a plug
  in `KnowseekWeb`, keyed by client address (behind a trusted proxy, by the
  forwarded address), with a limit and a window in config. Over the limit is
  HTTP 429 with `Retry-After`, and the web UI shows nothing for the card and
  keeps the search results.
- A fairness rule in `Knowseek.Cache` so that junk cannot starve real queries:
  for example one reserved in-flight slot for keys that were asked for twice,
  or a per-client share of the slots. Decide in the task and write it in
  `docs/ARCHITECTURE.md`.
- Evictions that favor entries that were read recently over entries that were
  only written (a junk key is written once and never read again).
- The warning log of dropped refreshes names the share of clients, if the
  fairness rule needs it.

## Acceptance criteria

- A client over its limit gets 429 with `Retry-After`; another client is not
  affected. Tests with a fake clock.
- A flood of distinct queries from one client does not keep another client's
  query `pending` (a test with a capped cache and a blocking resolver).
- A flood does not evict an entry that was read after it was written.
- The README API table lists the 429.
- `make check-quiet` passes.

## Out of scope

Users, API keys and quotas per user ([009](009-users-and-api-keys.md)); limits
on discovery sources ([016](016-limit-discovery-abuse.md)).
