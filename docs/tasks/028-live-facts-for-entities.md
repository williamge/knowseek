# 028. Live facts for entities

- Status: open
- Area: product design + `Knowseek.Lookup`/`Knowseek.Discovery`
- Depends on: none

This is a design session with the owner, not an implementation task. Write no
code until the session has recorded its decisions in an ADR.

## Goal

When a query is about an entity with live state (example: "knicks"), Knowseek
should show current facts (is there a game on, the score, the next or last
game) next to the indexed results, and keep them fresh while the user looks.

## Context

The index holds text documents (chunks and embeddings). Live facts are small
structured state with a validity window of seconds. They do not belong in
`documents`/`chunks`.

Proposed shape to evaluate:

- A separate "card" answer type next to the hits.
- Entity resolution first.
- Refresh at view time: the UI polls a small endpoint. The backend caches per
  entity with a TTL that depends on state: live game 10-30 s, scheduled game
  until tip-off, final game hours. Single-flight, so many viewers cost one
  upstream call.
- Nothing runs when nobody is looking. This is the opposite of the removed
  topic cron (see "What the removed version did" in
  [027](027-rethink-topics.md)).

## What we verified

Manual probes on 2026-10-31. Sources can change; re-check before relying on them.

- ESPN's scoreboard JSON
  `https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard`
  returned live scores with no API key. It is an undocumented endpoint: terms
  and stability are unknown.
- `https://cdn.nba.com/static/json/liveData/scoreboard/todaysScoreboard_00.json`
  did NOT return JSON to a plain curl (not diagnosed).
- Wikidata `wbsearchentities` for "knicks" returned Q131364 "New York Knicks"
  (NBA team) first.
- Wikipedia search for "knicks" returns the team article and the 2025-26
  season article.
- Untested candidates: balldontlie, TheSportsDB, MLB and NHL public APIs,
  injury reports.

## Questions for the session

- [ ] What should a "knicks" search show (game card live/last/next, record and
  standings, roster and injuries, recent news, the Wikipedia article), and in
  what order?
- [ ] How is an entity resolved (Wikidata search, an LLM intent step from task
  [007](007-query-planning.md), the index itself), and how is ambiguity handled?
- [ ] Which entity types get live sources first (sports, then maybe weather,
  flights, markets, elections), and how does a source declare what it can answer?
- [ ] Where does live state live (cache only, or a table), and what is the
  TTL/refresh model?
- [ ] API shape: an extra field on `POST /api/search`, or a separate endpoint
  the UI polls (leaning separate, for cacheability)?
- [ ] Single-flight and rate limiting against upstream sources. The Oban rule
  holds: the request path only enqueues.
- [ ] Source terms of use and failure behavior: upstream down, stale card, how
  the UI says "as of 21:41".
- [ ] What should following be, if anything? This absorbs the questions of task
  [027](027-rethink-topics.md): standing interest vs alerts vs digest vs
  warming the index; who it is for with no users; what the user sees when
  something new arrives; first-check timing; how failures surface.
- [ ] Relationship to the discovery-completion signal in task
  [006](006-discovery-status-for-callers.md) (a polling card should reuse it)
  and to query planning in task [007](007-query-planning.md).

## Out of scope

News search and general web coverage (tasks [003](003-web-search-source.md),
[004](004-feed-source.md)); users (task [009](009-users-and-api-keys.md)).
