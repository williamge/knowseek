# 033. Weather card

- Status: done
- Area: `Knowseek.Cards` (new provider), web card rendering
- Depends on: 031

## Goal

Show current weather for "weather in tokyo".

## Scope

- Entity side: task 030 returns `intent: :weather` and the place entity. The
  coordinates come from Wikidata P625 when present (Tokyo: 35.68944, 139.69167,
  which matches Open-Meteo to 3 decimals). When a place has no P625, fall back
  to Open-Meteo geocoding (`geocoding-api.open-meteo.com/v1/search`), which
  also gives the IANA timezone that Wikidata does not. Use the geocoder's
  timezone for local time in either case, or ask the forecast API for
  `timezone=auto`.
- Provider: Open-Meteo `/v1/forecast` with `current=temperature_2m,weather_code`
  (plus what the card shows), no key. Unit (Fahrenheit or Celsius) is config
  now; a user setting is later.
- Map `weather_code` to text and an icon name in one tested table.
- TTL: a few minutes (the API's `interval` is 900 s; do not poll faster).
  `as_of` is the response `time`.
- The free tier is non-commercial: note this in the config docs.

## Acceptance criteria

- `Req.Test` stubs and fixtures for forecast and geocoding; no network.
- `weather in tokyo` gives a card; a place without coordinates uses the
  geocoder fixture; geocoder failure gives `unavailable`.
- Every weather code in the table has a test.
- `make check-quiet` passes.

## Out of scope

Forecasts beyond current conditions, bare "weather" ([034](034-weather-location-context.md)).

## Outcome

Built ([ADR 0022](../decisions/0022-weather-card-terms-and-intent.md)):

- `Knowseek.Cards.Providers.OpenMeteo` (client `Knowseek.Cards.OpenMeteo`): one forecast request per place with Wikidata coordinates, `current` + 5 `daily` days, `timezone=auto`; metric facts, `observed_at` in UTC, the WMO code table (text + emoji, every code tested), TTL two thirds of `current.interval` (10 min, clamped 5-15 min). 429 is a rate limit; a malformed answer or HTTP error is `unavailable`/`stale` like the other cards.
- The intent rule: optional `Provider.intent/0`; `Cards.get/2`/`await/2` take `:intent`, which `CardController` passes. A place has weather only for the weather intent; `tokyo` is `none`; a team with the weather words keeps the team card.
- Web: `WeatherFacts.tsx` (conditions, high/low, wind, humidity, a 5-day strip, "as of" in the place's time zone, the Open-Meteo credit link), `lib/weather.ts` (US locale: °F/mph/in; others metric), tests for both.
- Fixture `fixtures/open_meteo/forecast_tokyo.json` recorded from the live API, README, ADR with the quoted terms.

Left out:

- The Open-Meteo geocoding fallback of the original scope: place kinds already require P625 coordinates, and `timezone=auto` replaces the geocoder's time zone.
- Configurable unit (Fahrenheit or Celsius): the UI picks it by locale; a user setting comes with accounts or [034](034-weather-location-context.md).
- Hourly forecast, alerts, air quality, sunrise/sunset in the UI (the card carries them).
- Bare "weather" ([034](034-weather-location-context.md)).

Follow-ups: none needed beyond 034. A commercial deployment needs Open-Meteo's paid plan and an API key setting (ADR 0022).
