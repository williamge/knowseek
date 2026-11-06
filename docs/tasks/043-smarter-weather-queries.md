# 043. Smarter weather queries

- Status: open
- Area: query understanding for the weather card (`Knowseek.Entities.Intent`, `Knowseek.Cards`, web UI)
- Depends on: 034

This is a design task, to be decided in a design session with the owner. Write
no code first, like task 028 (done; file removed, see git history). It is abstract
on purpose: a problem statement, evidence, and open questions. It is not a
design.

## Goal

Weather questions phrased the way people ask them should get a weather answer,
including the ones that name no resolvable place ("weather in my city",
"weather near me", "will it rain tomorrow").

The owner typed `weather in my city`. They did not get what they meant: the
page showed ordinary Wikipedia search results and no weather card.

## Context

What exists:

- `Knowseek.Entities.Intent.split/1` is plain code, not an LLM. It recognises
  two shapes only, ignoring case and extra spaces: `weather in <place>` and
  `<place> weather`. Anything else, including a bare `weather`, has no intent
  and is returned whole.
- `Knowseek.Entities.resolve/2` looks up the text that is left over in
  Wikidata and picks the first candidate that has a kind (`kind/1`). A
  weather card needs the intent `:weather` and a `:place` entity with
  coordinates. A place alone ("tokyo") gives no weather card.
- When nothing resolves, the card endpoint answers `none` and the web UI
  shows only the ordinary search results.
- The weather card is task 033 (done; file removed, see git history) (GitHub PR #32), merged
  on `main`, next to the sports-team card.
- Task [034](034-weather-location-context.md) plans browser-location context
  for a bare `weather`. It overlaps this task: decisions about where the
  user's location comes from should be made together.
- Task [007](007-query-planning.md) (LLM query planning) may replace the
  intent split. The module doc of `Intent` says so.

## Evidence

Probes on 2026-11-02 against `main` at `94db439` (task 031), run from one
developer machine. Intent: `Knowseek.Entities.Intent.split/1`, run with
`mix run`. Wikidata: `Knowseek.Entities.Wikidata.search/2` (the real
resolver: `wbsearchentities` with `language=en`, then `wbgetentities`, a
descriptive User-Agent, requests 4 to 5 seconds apart), on the text that
Intent leaves. For a query with no intent that is the whole query. "Top 3"
are the first three candidates in search order. "Kind" is what
`Knowseek.Entities.kind/1` gives for the candidate (`place`, `company`, or
none). Wikidata results can change over time.

| Query | Intent | Text looked up | Wikidata: candidates, top 3 labels (kind) | Top entity with a kind | App shows |
| --- | --- | --- | --- | --- | --- |
| `weather in my city` | weather | `my city` | 20: My City, My City, My City (none, none, none) | none | no card |
| `weather here` | none | `weather here` | 0 | none | no card |
| `weather near me` | none | `weather near me` | 0 | none | no card |
| `weather` | none | `weather` | 20: weather, Weather, Weather (none) | none | no card |
| `weather today` | none | `weather today` | 0 | none | no card |
| `weather tomorrow in paris` | none | `weather tomorrow in paris` | 0 | none | no card |
| `will it rain tomorrow` | none | `will it rain tomorrow` | 0 (one run: API error `cirrussearch-too-busy-error`) | none | no card |
| `is it cold outside` | none | `is it cold outside` | 0 | none | no card |
| `temperature in tokyo` | none | `temperature in tokyo` | 0 | none | no card |
| `tokyo forecast` | none | `tokyo forecast` | 0 (one run: API error `cirrussearch-too-busy-error`) | none | no card |
| `forecast for the weekend` | none | `forecast for the weekend` | 0 | none | no card |
| `weather in nyc` | weather | `nyc` | 20: New York City (place), Nyctereutes procyonoides, Nyctemera (none) | New York City (place) | weather card for New York City (per the code path, not probed) |
| `wether in tokyo` | none | `wether in tokyo` | 0 | none | no card |
| `weather in tokyo and osaka` | weather | `tokyo and osaka` | 0 | none | no card |
| `weather in tokyo` (control) | weather | `tokyo` | 20: Tokyo (place), Tokyo (place), Sony Group (company) | Tokyo (place) | weather card for Tokyo (per the code path, not probed) |
| `tokyo` (control) | none | `tokyo` | same as above | Tokyo (place) | place resolves but no intent, so no weather card |

The Intent and Wikidata probes ran on `main` at `94db439`, before the
weather card merged (`Intent` has not changed since; `wikidata.ex` and
`entity.ex` have). "App shows" is derived from the code path: a card needs the
intent `weather` and a `place` with coordinates, and `none` gives only the
search results. Afterwards, with the card on `main`, I ran the real card
endpoint (`GET /api/cards?q=...`, a local server, read-only, polled until it
was no longer `pending`):

| Query | Card endpoint status | Entity | Card |
| --- | --- | --- | --- |
| `weather in my city` | `none` | none | none |
| `weather here` | `none` | none | none |
| `weather in tokyo` (control) | `fresh` | Tokyo (Q1490, place) | weather card |
| `weather in nyc` | `pending` at the one read after 8 s (entity New York City, Q60, place); I did not poll further | New York City | not seen yet |

So the two owner-style queries get `none`, as predicted, and the control gets
a weather card. The other rows of the first table were not run through the
endpoint.

What `weather in my city` does: Intent matches the first shape and extracts
the place text `my city`. Wikidata returns 20 candidates, the first three
labelled "My City". None of the 20 has a kind (a supported place type with
coordinates), so no candidate is chosen, the resolution is `none`, and the page shows the ordinary Wikipedia
results. The query reached the weather path, and the phrase "my city" is
treated as a name, not as the user's location.

Not probed: the web UI, Open-Meteo (geocoding or forecast) on its own, the
endpoint for the other 12 queries, browser geolocation, and any LLM planner. Queries
other than the 14 above (other spellings, other languages, other places) were
not tried. The two `cirrussearch-too-busy-error` answers are Wikidata being
busy, not an answer about the query; re-running those two queries returned 0
candidates both times.

## Problems seen

Only what the evidence shows.

1. A place that is not a name (`my city`) is looked up as a name. Wikidata
   returns look-alike items ("My City") and nothing is a place, so the user
   gets no card and no hint why.
2. `here`, `near me`, and a bare `weather` are not recognised as weather at
   all (no intent). The text `weather` even matches Wikidata items about the
   concept, which have no kind.
3. The split knows two shapes. `weather today`, `weather tomorrow in paris`,
   `temperature in tokyo`, `tokyo forecast`, `forecast for the weekend`, and
   the question shapes get no intent, so each is looked up whole in Wikidata
   and finds nothing.
4. A misspelling of the intent word (`wether in tokyo`) gets no intent.
5. More than one place (`weather in tokyo and osaka`) is looked up as one
   string and finds nothing.
6. An abbreviation can work by luck: `nyc` resolves to New York City because
   it is the first candidate with a kind. The Wikidata search ranks two
   taxa (an animal and an insect genus) next.
7. Every query, even one that has nothing to do with a place, causes a Wikidata
   lookup of the whole text. Wikidata answered busy twice in 22 searches. That is a cost and a rate-limit risk to keep in mind in the
   design.

## Open questions

Not answered here. For the design session with the owner.

- **Where the user's location comes from** for `my city`, `here`, `near me`,
  and a bare `weather`: browser geolocation with a permission prompt, a
  saved home place, an IP-based guess, or something else. Privacy, accuracy,
  and what the backend may know or log. How this fits task 034.
- **What to show when the location is unknown:** ask for it, show a prompt in
  the card, or show nothing.
- **Time ranges** (today, tomorrow, the weekend, hourly): are they in scope,
  and should the card answer them or only show the current conditions?
- **Question-shaped queries** (`will it rain tomorrow`, `is it cold
  outside`) versus keyword queries (`tokyo forecast`): should both get an
  answer, and what does an answer look like?
- **Other weather intents:** rain, snow, wind, UV, air quality.
- **Typos and aliases** (`nyc`, `wether`): how far to go, and where the alias
  list lives.
- **Multi-place queries** (`tokyo and osaka`): one card per place, the first
  place, or nothing.
- **How this relates to LLM query planning** (task [007](007-query-planning.md))
  versus plain deterministic rules: cost, latency, failure modes, and whether
  the plain rules stay as the fast path.
- **Units** (Celsius or Fahrenheit) and whether the user chooses them.
- **Reuse of the location context** by other cards later.

## Scope

To be decided in a design session; write no code first.

## Acceptance criteria

- The decisions are recorded in an ADR (to be written in the design session;
  none exists yet).
- This task is split into implementation tasks, with their own numbers.

## Out of scope

Changes to the card UI before the design is agreed.
