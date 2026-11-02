# Open-Meteo fixtures

Recorded responses of Open-Meteo's forecast API (`https://api.open-meteo.com/v1/forecast`), captured with `curl` on 2026-11-01 for the tests of `Knowseek.Cards.Providers.OpenMeteo` (task 033).

| File | Request | Contents |
| --- | --- | --- |
| `forecast_tokyo.json` | `latitude=35.68944&longitude=139.69167&current=temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m,wind_direction_10m,is_day&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code,sunrise,sunset&timezone=auto&forecast_days=5` | Tokyo, as Open-Meteo answered: `current` at 2026-11-01T10:00 local time (17.0 °C, clear sky, `interval` 900), five `daily` entries, `timezone` `Asia/Tokyo`, `utc_offset_seconds` 32400. Only `generationtime_ms` was dropped; the file is otherwise as received and pretty-printed. |

Open-Meteo snaps the request to its model grid (it answers `latitude: 35.7`, `longitude: 139.6875` for Tokyo's coordinates).

## License

Open-Meteo's data is licensed CC BY 4.0, free for non-commercial use (<https://open-meteo.com/en/terms>, ADR 0022). The file is a test fixture; the application credits Open-Meteo.com on the card.
