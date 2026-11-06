# 0027. Wikimedia: at most 3 requests at once, entity lookups first

- Status: Accepted
- Date: 2026-11-06

## Context

Wikimedia asks every API client to "limit the number of concurrent requests to 3 or fewer", and its rate limits "apply across all sites and platforms" ([Wikimedia APIs/Rate limits](https://www.mediawiki.org/wiki/Wikimedia_APIs/Rate_limits), read 2026-11-06). Knowseek calls two Wikimedia sites:

| Caller | Requests | Cap before | At once, worst case |
|---|---|---|---|
| `Discovery.Sources.Wikipedia` (Oban `discovery` jobs) | a search, then one page at a time | queue of 5 jobs | 5 |
| `Entities.Wikidata` (fetch tasks of the entity cache) | a search, then the details | `max_in_flight` 4 | 4 |

So up to 9 requests could run at once (issue #66, `docs/notes/storage-and-licenses.md`).

Options:

| Option | Waits | Against |
|---|---|---|
| Smaller pools (queue 1, cache 2) | jobs in Oban; entity fetches dropped, the client polls | a job holds its slot while it embeds; the cap is a sum spread over two settings; a new Wikimedia caller breaks it |
| Oban queue limits | jobs in Oban | entity lookups are not jobs; a global limit needs Oban Pro |
| One shared limiter | the caller, for one request | a new process; waiting counts against the entity cache's timeout |

## Decision

`Knowseek.Wikimedia` is one limiter with 3 slots (`max_concurrent`). Every Wikimedia request runs inside `Knowseek.Wikimedia.run/3`, which holds a slot for that request only.

- Entity lookups are `:interactive`: a user waits. They may use every slot and get a freed slot first.
- Discovery is `:background`: it holds at most 2 slots (`background_max`), so one slot is always free of discovery.
- A caller with no free slot waits in memory, in order within its class, with no time limit. It does not give up: every holder ends within its HTTP timeouts.
- The limiter monitors holders and waiters. A caller that dies (the entity cache kills a fetch at its timeout) frees its slot or leaves the queue.
- Req's retries of a Wikipedia request keep the slot, including the wait before a retry.

The Oban queue (5) and the entity cache (4 in flight, 1 reserved for refreshes) stay as they are; above 3 they wait for a slot.

## Consequences

- At most 3 Wikimedia requests run at once per node, and at most 2 of them for discovery.
- An entity lookup waits only behind other entity lookups. The wait counts towards the cache's 15 s timeout: behind three slow Wikidata requests a lookup can time out and back off for a minute.
- Steady entity traffic can hold all 3 slots and delay discovery jobs; they run longer, they do not fail.
- The limit is per node, like the other in-memory limits. Several nodes would need a shared limit.
- A new Wikimedia caller must call `Knowseek.Wikimedia.run/3` with its class.
- Not covered: the 200 requests a minute volume limit, and a shared stop after a Wikipedia 429 (each caller handles its own).
