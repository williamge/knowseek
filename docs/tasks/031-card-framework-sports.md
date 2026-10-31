# 031. Card framework and sports-team card

- Status: open
- Area: new public context `Knowseek.Cards`, `KnowseekWeb`, web (`frontend/src`)
- Depends on: 030

## Goal

Show a card of live facts above the results, for a sports team ("knicks"),
using ESPN. This task builds the framework the company and weather cards reuse.
Design: [ADR 0017](../decisions/0017-live-fact-cards.md), decision 4.

## Scope

- `Knowseek.Cards` public API: `get(entity)` reads the cache and returns a card
  map with `type`, `title`, `facts`, `status` (`fresh | stale | pending |
  unavailable`) and `as_of` (UTC datetime), or `:none` when no provider handles
  the entity type. It never calls a provider.
- A `Knowseek.Cards.Provider` behaviour: `handles?(entity)`, `fetch(entity)`
  returning `{:ok, card, ttl_ms}` or `{:error, reason}`. The provider list is
  config (rule 4). Providers are read-only and never write to the database.
- An in-memory cache (ETS) and a refresher under the application supervisor
  (a `Task.Supervisor` plus a registry, or one GenServer per key). When an entry
  is missing or past its TTL, `get/1` asks the refresher to start a refresh and
  returns at once: `pending` with nothing cached, `stale` with something.
- Single-flight per entity: concurrent requests start one upstream call. The
  upstream call has a short timeout. On failure keep the old value (`stale`,
  or `unavailable` if nothing ever succeeded) and back off briefly before the
  next attempt. The cache is disposable; no Oban job, table or migration.
- ESPN provider: match the Wikidata label to ESPN `displayName` from the
  `/teams` list (alias "Los Angeles Clippers" = "LA Clippers"; tie-break the
  duplicate "Denver Nuggets" by league), then read `/teams/<slug>` for record
  and next event, `/schedule` for the last game and score, `/roster` for
  injuries. TTL by `status.type.state`: `in` 10-30 s, `pre` until start time,
  `post` hours. Do not go below the 3 s upstream `max-age`.
- JSON endpoint, for example `GET /api/entities/:id/card`, with the response
  shape above; `types.ts` mirrors it in the same branch (rule 9).
- Before any endpoint exposes entity resolution: a cap on in-flight fetches in
  `Knowseek.Cache` and a cache-wide backoff on 429/maxlag (honoring
  Retry-After), because N distinct queries mean N Wikidata calls and junk
  queries evict real entries.
- Frontend card component above the results: facts, an "as of <time>" stamp, a
  stale notice. Polls about every 0.5-1 s while `pending`, then at a cadence
  derived from the response (live game 10-30 s), and stops while the page is
  hidden.
- Update `docs/ARCHITECTURE.md`, the `README.md` API table, and the `AGENTS.md`
  context list.

## Acceptance criteria

- Tests use `Req.Test` stubs and ESPN fixtures in
  `backend/test/support/fixtures.ex`; no network.
- Single-flight: N concurrent requests make one upstream call.
- Stale on failure: a failed refresh keeps the old card with `stale`; with
  nothing cached the status is `unavailable`.
- Backoff: after a failure, requests inside the backoff window start no new
  upstream call.
- Pending then fresh: a cold request returns `pending`, and a later request
  returns `fresh` with `as_of`.
- TTL by state: scheduled, in-progress and final fixtures give three TTLs.
- The request path never hits the network: a cold request returns without the
  stub being called by the request itself.
- Frontend tests: poll cadence by status, the as-of stamp, and the stale notice.
- `make check-quiet` passes.

## Out of scope

Companies and weather ([032](032-company-card.md), [033](033-weather-card.md)),
news headlines and odds, following, WebSocket/SSE push.
