# 033. Weather card

- Status: done
- Area: `Knowseek.Cards` (new provider), web card rendering
- Depends on: 031

## Goal

Show current weather for "weather in tokyo".

## Scope

- Entity side: task 030 returns `intent: :weather` and the place entity. The
  coordinates come from Wikidata P625 (Tokyo: 35.68944, 139.69167, which
  matches Open-Meteo to 3 decimals). Ask the forecast API for `timezone=auto`
  for local time.
- Provider: Open-Meteo `/v1/forecast` with `current=temperature_2m,weather_code`
  (plus what the card shows), no key. The backend returns metric values; the
  web UI picks the units from the reader's locale (US: Fahrenheit, mph,
  inches; others metric). A user setting is later.
- Map `weather_code` to text and an icon in one tested table.
- TTL: a few minutes (the API's `interval` is 900 s; do not poll faster).
  `as_of` of the card is when it was fetched; the observation time is in the
  facts.
- The free tier is non-commercial: note this in the config docs.

Changed from the first draft of this task, and why:

- *Geocoder fallback struck.* The draft had a fallback to Open-Meteo geocoding
  (`geocoding-api.open-meteo.com/v1/search`) for a place without Wikidata
  coordinates. A place only has the kind `:place` when it has coordinates
  (`Knowseek.Entities.kind/1`), so such an entity never reaches the provider,
  and `timezone=auto` gives the time zone. The geocoder was not built, and its
  acceptance criteria below are struck.
- *Forecast strip added.* The draft left "forecasts beyond current conditions"
  out of scope. A card with a few days of high and low is what a weather card
  shows, and it costs nothing extra: the `daily` fields come in the same
  Open-Meteo call as `current`. It was added on purpose, with 5 days (today
  and 4 more); hourly data, alerts and the like stay out.
- *Unit config became locale detection.* The draft said the unit is config
  "now". Nothing server-side needs it, so the UI decides by locale
  (`frontend/src/lib/weather.ts`).

## Acceptance criteria

- `Req.Test` stubs and fixtures for the forecast; no network. (~~and
  geocoding~~)
- `weather in tokyo` gives a card. (~~A place without coordinates uses the
  geocoder fixture; geocoder failure gives `unavailable`.~~) An HTTP error, a
  429 or a malformed answer gives `unavailable` (nothing cached) or `stale`.
- Every weather code in the table has a test.
- A place has a weather card only for the weather intent (ADR 0022).
- `make check-quiet` passes.

## Out of scope

Hourly forecasts, alerts, bare "weather" ([034](034-weather-location-context.md)).

## Outcome

Built ([ADR 0022](../decisions/0022-weather-card-terms-and-intent.md)):

- `Knowseek.Cards.Providers.OpenMeteo` (client `Knowseek.Cards.OpenMeteo`): one forecast request per place with Wikidata coordinates, `current` + 5 `daily` days, `timezone=auto`; metric facts, `observed_at` in UTC, the WMO code table (text + emoji, every code tested), TTL two thirds of `current.interval` (10 min, clamped 5-15 min). 429 is a rate limit; a malformed answer or HTTP error is `unavailable`/`stale` like the other cards.
- The intent rule: optional `Provider.intent/0`; `Cards.get/2`/`await/2` take `:intent`, which `CardController` passes. A place has weather only for the weather intent; `tokyo` is `none`; a team with the weather words keeps the team card.
- Which place: for the weather intent the entity is chosen among the place candidates by sitelinks, so `weather in new york` is the city and `weather in washington` is D.C. (ADR 0022 has the rule and the table). The entity cache holds candidates and the choice is made per intent.
- One cache per card provider (`Knowseek.Cards.cache_name/1`), so a rate limit from one upstream stops only its own cards.
- Web: `WeatherFacts.tsx` (conditions, high/low, wind, humidity, a 5-day strip, "as of" in the place's time zone, the Open-Meteo credit and the CC BY 4.0 link), `lib/weather.ts` (US locale: °F/mph/in; others metric; an empty or invalid `navigator.language` is `en-US`), tests for both. An alternative place chip searches `weather in <label>`.
- Fixtures `fixtures/open_meteo/forecast_tokyo.json` (recorded from the live API) and Wikidata answers for `new york`, `washington`, `london`, `georgia`, `cambridge`, with READMEs.

Left out:

- The Open-Meteo geocoding fallback (see "Changed from the first draft").
- A user setting for units, hourly forecast, alerts, sunrise/sunset in the UI (the card carries them).
- Bare "weather" ([034](034-weather-location-context.md)).
- Reaching an alternative that has the same label as the top entity (Springfield, Cambridge, Georgia): [041](041-card-by-entity-id.md).

A commercial deployment needs Open-Meteo's paid plan and an API key setting (ADR 0022).
