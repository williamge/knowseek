# 042. Evict cache entries that were never read first

- Status: open
- Area: `Knowseek.Cache`
- Depends on: none

## Goal

Make a flood of distinct junk keys unable to push real entries out of a cache, by evicting the entries that were written and never read again before the ones that were read.

## Context

Left out of task [039](039-rate-limit-anonymous-endpoints.md) (see its Outcome and [ADR 0023](../decisions/0023-rate-limiting-anonymous-endpoints.md)). `Knowseek.Cache` drops the least recently *written* 10% when it passes `:max_entries`. A junk key is written once and never read again, but it is newer than a real entity that was written a day ago, so the real entity goes first. The per-client rate limit slows this down (one client can write about 2 new entity keys a second), but many addresses add up, and the entity table has 5000 entries.

`get/4` reads the ETS table in the caller's process, and the table is `:protected`, so a read cannot record itself today.

## Scope

- Record that an entry was read, cheaply: for example a `:public` counter row updated with `:ets.update_counter/4` (a read bumps `{:reads, key}`), or a cast to the cache process that is sampled. Measure the cost on the card endpoint's read path.
- Evict by "read count, then age": entries never read after the first write go first.
- Keep the API of `Cache` and the existing eviction tests (`max_entries`, keys being fetched stay).

## Acceptance criteria

- A test with a small `:max_entries`: a key that was read after it was written survives a flood of distinct keys that were never read.
- The read path does not call the cache process (it stays a table read plus at most a counter update).
- `make check-quiet` passes.
