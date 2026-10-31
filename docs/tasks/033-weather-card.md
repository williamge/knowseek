# 033. Weather card

- Status: open
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
