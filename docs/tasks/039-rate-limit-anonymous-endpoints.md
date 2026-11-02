# 039. Rate-limit anonymous endpoints

- Status: done
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
- ~~The warning log of dropped refreshes names the share of clients, if the
  fairness rule needs it.~~ Struck: `Cache.get/4` takes a key, not a request,
  so the cache does not know clients, and the fairness rule chosen does not
  need it (the per-client limit tells clients apart before the cache is
  called). The drop warning names the in-flight count and the reserve instead.

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

## Outcome

Built (decisions and arguments: [ADR 0023](../decisions/0023-rate-limiting-anonymous-endpoints.md)):

- `Knowseek.RateLimiter`: an in-repo token bucket (one process, integer math, a fake clock for tests). Full buckets are swept every minute, at most 50,000 are kept, and past the cap the least recently used 10% go, so the table cannot grow without bound. `hit/4` waits at most 100 ms and fails open, logging at most once every ten seconds.
- `KnowseekWeb.Plugs.RateLimit`, a plug of the endpoint before `Plug.Parsers`, on `GET`/`HEAD /api/cards`, `POST /api/search` and `POST /api/documents`: one budget per endpoint and client (`config :knowseek, KnowseekWeb.RateLimit`: `cards` 120 then 2 a second, `search` and `documents` 30 then one every 2 s). `429` with `{"errors": {"detail": "Too many requests"}}` and `Retry-After`, before the body is read. Request bodies are capped at 1 MB (`413`). `/api/health` and the reads of `/api/documents` are not limited. Off in `config/test.exs`.
- `KnowseekWeb.ClientIp`: the client is the socket address (an IPv6 client is its /64, an IPv4-mapped address is the IPv4 one). `X-Forwarded-For` counts only from a socket address in `trusted_proxies` (CIDRs, `TRUSTED_PROXIES`, default none; compose forwards it), read from the right. CIDRs are parsed once, a malformed or non-canonical entry stops the application at start, and a rightmost entry that is not a bare address falls back to the proxy's address.
- `Knowseek.Cache`:
  - `reserve_for_refresh`: slots that only refreshes of keys that hold a value may use. It keeps those refreshes alive during a flood of new keys; it does **not** protect a brand-new real query, which competes with junk for the other slots (the per-client limit is what protects it, and many source addresses are not stopped). Entity cache 1 of 4, cards cache 2 of 8. `empty_values` (the entity cache: `[:none]`) makes a cached "nothing" count as a new key.
  - Eviction favors entries that were read: fewest reads first, oldest among equals. `get/4` counts a read with one `:ets.update_counter/4` on a public table and still never calls the cache process. A flood of unread junk does not evict an entry that was read after it was written.
- Frontend: `ApiError.retryAfterMs`; the card poller waits for `Retry-After` (1-60 s, 5 s without it), also when the tab becomes visible or the browser online meanwhile, keeps the card and shows nothing; a limited search shows the muted message "Too many requests, retrying shortly" and asks again after `Retry-After`, giving up with the server's message after three tries; the discovery watcher keeps its results and waits for `Retry-After` before the next check.
- Tests: limiter semantics (burst, refill, `Retry-After` rounding, independent keys, memory cap, LRU, sweep, timeout path), `ClientIp` (trust on and off, spoofing, IPv6, CIDR errors), the plug per endpoint and its placement before the parsers, the flood regressions (100 distinct junk queries from one client: 3 reach the cache; with a capped cache and a blocking resolver, a second client's query starts while the flood is blocked), cache fairness and read-aware eviction, and the frontend 429 handling.

Left out:

- A per-client share of the cache's in-flight slots, and a drop warning that names the share of clients: struck from the Scope above. The cache does not know clients (ADR 0023).
- Limits per user or API key ([009](009-users-and-api-keys.md)), and on discovery sources ([016](016-limit-discovery-abuse.md)).
- Limits are per node and start over on restart. A flood from many addresses is not stopped (a real new query can stay `pending`, and a Wikidata 429 still blocks entity resolution cache-wide).
