# 0023. Rate limiting for anonymous endpoints, and a fairness rule in the cache

- Status: Accepted
- Date: 2026-10-31

Builds on [0017](0017-live-fact-cards.md) (the cache that runs refreshes in the background). See `docs/tasks/039-rate-limit-anonymous-endpoints.md`.

## Context

There is no authentication (task 009 is parked), and the repository is public. The review of the card framework (task 031, PR #30) found that one anonymous client could do four things:

1. Keep every in-flight slot of the entity cache busy with distinct junk queries (`GET /api/cards?q=<junk>`: 10-20 a second is enough for 4 slots), so a real query stays `pending`.
2. Write junk entries until the oldest real ones leave the 5000-entry table.
3. Provoke a Wikidata 429 that stops entity resolution for every client for up to ten minutes.
4. Enqueue discovery jobs and make the server embed text through `POST /api/search`, and make it embed and store text through `POST /api/documents`.

Two different things are missing: a limit on how much one client may ask, and a rule about who gets the slots that exist.

## Decision

### A per-client token bucket on three endpoints

`KnowseekWeb.Plugs.RateLimit` runs in the controllers of `GET /api/cards`, `POST /api/search` and `POST /api/documents`. Each endpoint is a bucket with its own budget per client: `{limit, window_ms}` in `config :knowseek, KnowseekWeb.RateLimit` is a burst of `limit` requests that refills `limit` per `window_ms`. The defaults are generous for one person on a laptop and cut off a script: 120 card requests, then 2 a second (the card poller asks every 0.7 s while a query is pending and about every 15 s afterwards); 30 searches or ingests, then one every 2 s. Over the limit the answer is `429`, the usual error body (`{"errors": {"detail": "Too many requests"}}`) and a `Retry-After` header in whole seconds. The request does not reach the controller, so nothing is embedded, enqueued or cached for it. `GET /api/health` (probes) and the reads of `GET /api/documents` (the UI polls them to see what discovery adds) are not limited. `enabled: false` turns the limit off, and `config/test.exs` does.

The limiter is `Knowseek.RateLimiter`, in the repository, no dependency. One GenServer owns a map of buckets, so the check and the take cannot race and the code stays small. Each hit is one call of a few microseconds; the endpoints behind it cost milliseconds. The math is integer (a token is `window_ms` units, a millisecond adds `limit` units), so `Retry-After` is exact and tests with a fake clock are deterministic.

**Bounded memory.** The keys come from the network, so the table must not be growable. A bucket that has refilled completely is the same as no bucket: a sweep every minute drops those without losing anything. At most `max_buckets` (50,000) are kept; a new key that would pass the cap sweeps the full buckets first and, if that is not enough, drops the least recently used 10% at once, so the cost per hit stays low. The price is that a client that sends from more distinct addresses than the cap can reset other clients' buckets; it cannot grow memory. An IPv6 client is keyed by its /64, because one subscriber usually owns a whole /64 and would otherwise get a fresh bucket per address.

**Who the client is.** The socket's remote address. `X-Forwarded-For` is read only when the socket address belongs to a trusted proxy, configured as CIDRs in `trusted_proxies` (`TRUSTED_PROXIES` in `config/runtime.exs`, comma-separated; default empty, so the header is ignored and cannot be spoofed). For a trusted proxy the header is read from the right: each proxy appends the address it saw, so the left entries are the client's own words. The client is the rightmost entry that is not a trusted proxy. A malformed entry stops the application at start. An IPv4-mapped IPv6 address (what a dual-stack listener reports for an IPv4 client) counts as its IPv4 address.

**Deployment note.** Behind a reverse proxy without `TRUSTED_PROXIES`, every client has the address of the proxy and they share one budget: set it to the proxy's network, and make the proxy append to `X-Forwarded-For` (nginx `$proxy_add_x_forwarded_for`, most load balancers by default). The app should not be reachable directly from the internet when the proxy is trusted: a direct request carries the client's own address as the socket address and is limited by it, which is correct, but a trusted network that a client can reach (for example a shared Docker network) lets that client choose its key.

### A fairness rule in `Knowseek.Cache`

`max_in_flight` bounds the upstream load but does not say who gets the slots. The new option `reserve_for_refresh` reserves that many of the slots for refreshes of keys that already hold a value (an expired entity or card). A key with no value, never fetched or fetched only with failures, is a *new key*, and starts a fetch only while fewer than `max_in_flight - reserve_for_refresh` fetches run. A refresh may use any slot. The entity cache has 4 slots with 1 reserved, the cards cache 8 with 2. So with the new-key share full of junk, a refresh of a key with a value still starts, and a real new key starts as soon as one fetch ends. The default is `0`, the old behavior; the API of `Cache` is otherwise unchanged. The option must leave a slot for new keys (`reserve < max_in_flight`), or the cache refuses to start.

### What was not decided this way

- *A library* (Hammer, PlugAttack, ExRated). Each is a dependency with a store, a supervision story and its own idea of a key; what we need is 100 lines whose memory bound we can argue. The choice says nothing about their quality, and none was added, so there is no license to check. If per-user quotas arrive (task 009), a library or a database-backed limiter may fit better, and the plug is the only caller of `Knowseek.RateLimiter`.
- *A sliding-window log.* It stores a timestamp per request, so one client can grow memory by the limit. A bucket stores two numbers.
- *Lock-free ETS counters.* A fixed window can be done with `:ets.update_counter/4` alone, but allows twice the limit at a window border and cannot express the exact `Retry-After`. A compare-and-swap loop on a bucket row is possible; one process is simpler, and the call is not the bottleneck at this scale.
- *Tracking who asked for a key* in the cache ("a per-client share of the slots"), or *treating a key that was asked for twice as a real one*. The cache does not know clients, and a poller asks repeatedly by design, but so can a script. The per-client limit is what tells clients apart; the reserve only keeps refreshes alive.

## Consequences

- One client can no longer start more than the `cards` budget of Wikidata lookups: 120 at once, then 2 a second. That is below what keeps the 4 slots busy for long, and a client that sends junk gets `429` itself. Many clients (many addresses) can still add up, and a Wikidata 429 still blocks entity resolution cache-wide, by design (ADR 0017); the limit makes it much harder to cause from one machine, not impossible from many. A second look at the 5000-entry table is left to task [042](../tasks/042-evict-unread-cache-entries.md) (evictions that favor entries that were read).
- The limits are per node and lost on restart. With several nodes the effective limit is the sum. That is acceptable until there is more than one node.
- The UI treats `429` as "slow down", not as a failure: the card poller waits for `Retry-After` (1 to 60 s) and keeps the card; a search that is limited shows "Too many requests, retrying shortly", asks again after `Retry-After` and gives up with the server's message after three tries.
- A shared NAT or a proxy that is not configured puts many people in one bucket. The defaults leave room for a household; `TRUSTED_PROXIES` fixes the proxy case.
- The defaults are guesses for local use, not measured. Change them in `config/config.exs`.
