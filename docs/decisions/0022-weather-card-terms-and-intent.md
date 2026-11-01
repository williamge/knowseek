# 0022. Weather card: Open-Meteo terms and the intent rule

- Status: Accepted
- Date: 2026-11-01

Builds on [0017](0017-live-fact-cards.md) (live fact cards). Task [033](../tasks/033-weather-card.md).

## Context

The weather card (task 033) answers `weather in tokyo` and `tokyo weather` from Open-Meteo's forecast API. Two things need a decision that a later agent must know: the terms of that API, and when a place gets a weather card at all. Entity resolution already splits an intent word off the query (`Knowseek.Entities.Intent`) and returns `intent: :weather`; before this task nothing used it.

## Decision

### Open-Meteo terms

Open-Meteo's free API at `api.open-meteo.com` needs no key, but its terms (<https://open-meteo.com/en/terms>, read on 2026-11-01) limit it. The relevant sentences:

> You may only use the free API services for non-commercial purposes. You accept to the CC-BY 4.0 licence, as specified in the licence conditions.

> Less than 10'000 API calls per day, 5'000 per hour and 600 per minute.

> Non-commercial use is defined as elaborated by creative commons. [...] Private or non-profit websites or apps that do not have subscriptions or advertising [...] qualify as non-commercial use. On the other hand, the following examples are considered commercial use: Websites or apps that have subscriptions or display advertisements. Commercial products or promotional activities.

> If you plan to use our service for commercial purposes or require additional API calls, we kindly request you to consider subscribing to our API plans.

The pricing table on the same page lists "Commercial use" as not allowed on the free tier and allowed on the Standard, Professional and Enterprise plans.

What follows for Knowseek:

- **Attribution.** CC BY 4.0 requires credit. Every weather card shows a visible link, "Weather data by Open-Meteo.com", to <https://open-meteo.com/>. The backend puts `source` and `source_url` in the card facts and the UI renders them, so the credit cannot be left out by one client.
- **Non-commercial only.** The default configuration (the free endpoint) is for a personal or non-profit deployment without subscriptions or advertising. A commercial deployment must not use it: it needs Open-Meteo's paid API plan, which has its own host and an API key, so it needs a small code change (a `base_url` and a key in `config/runtime.exs`). Nothing here prepares for that beyond `Knowseek.Cards.OpenMeteo` having a configurable `base_url`.
- **Volume.** One forecast per place per 10 minutes at most (the card TTL), and one request in flight per place (the cards cache is single-flight). The 10 000 calls a day limit is far away; the cards cache also stops all fetches for `Retry-After` after an HTTP 429 (`Cache.rate_limited/1`).
- **Identification.** Requests send a descriptive User-Agent (`Knowseek/0.1.0 (https://github.com/williamge/knowseek)`).

### Intent rule: a place has a weather card only for the weather intent

A place entity (a Wikidata item of a supported place type with coordinates, `Entities.kind/1 == :place`) gets a weather card **only when the query's intent is `:weather`**:

| Query | Entity, intent | Card |
| --- | --- | --- |
| `weather in tokyo`, `tokyo weather` | place, `:weather` | weather card |
| `tokyo` | place, none | `none`: a search, not a weather question |
| `knicks weather`, `weather in knicks` | sports team, `:weather` | the team card (NBA teams), else `none` |
| `weather in nvda` | company, `:weather` | `none` |
| `knicks` | sports team, none | the team card |

The weather intent is therefore a **requirement of the weather provider, not a filter on all providers**. A team does not have weather, and the query still names the team clearly, so the team card is the best answer: the weather word is ignored. A place is the opposite: `tokyo` alone is most likely a search for the city, and a weather card above those results would be noise.

Mechanism: `Knowseek.Cards.Provider` gets an optional callback `intent/0`. `Cards.get/2` and `Cards.await/2` take the query's intent (option `:intent`, which `CardController` passes from `Entities.resolve/2`) and skip a provider that defines `intent/0` unless it equals the query's intent. Providers that do not define it (ESPN) apply whatever the intent was. The card is cached per place, not per query, so `tokyo weather` and `weather in tokyo` share one forecast.

### Other choices

- **Coordinates** are the entity's Wikidata P625. A state or a country is one point (Texas: 31, -100), so its forecast is for that point, not an area average. There is no geocoder fallback: an entity without coordinates is not a `:place` (`Entities.kind/1` needs them), so it never reaches the provider. Task 033 mentioned Open-Meteo geocoding as a fallback; it is not built because the place kinds already require P625, and `timezone=auto` gives the time zone.
- **Units.** The card carries metric values (°C, km/h, mm). The web UI converts: the US locale gets °F, mph and inches, every other locale metric (`frontend/src/lib/weather.ts`). The user's choice is a later setting.
- **Weather codes.** The WMO code to text and emoji table is in the backend (`Knowseek.Cards.Providers.OpenMeteo.condition/1`, `icon/2`), one place, tested for every code Open-Meteo returns. The UI shows what the card says.
- **TTL.** Open-Meteo updates `current` every 15 minutes (`current.interval`, 900 s). The card is fresh for two thirds of the interval, 10 minutes, clamped to 5-15 minutes. Stale and unavailable work as for the other cards.
- **Local time.** `current.time` is local without offset. The card carries `observed_at` in UTC with the IANA `timezone`; the UI shows "as of 10:00 AM GMT+9" with `Intl` (it names zones as GMT offsets for most zones outside the reader's locale, not as "JST").

## Consequences

- Task [034](../tasks/034-weather-location-context.md) (bare "weather") can reuse the provider with a place built from the browser's location; it needs a way to give the provider coordinates without a Wikidata entity.
- A commercial deployment is blocked on a paid Open-Meteo plan. This is a license obligation; the code does not enforce it.
- The weather card is cached per place for 10 minutes, so a popular place costs one call per 10 minutes whatever the number of users.
