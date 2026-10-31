# 034. Location context for bare "weather"

- Status: open
- Area: web (`frontend/src`), card endpoint
- Depends on: 033

## Goal

A query "weather" with no place shows the weather where the user is. The
location is context for the request, not an entity.

## Scope

- Frontend asks for the browser's geolocation (`navigator.geolocation`) only
  when the query is a bare weather intent, behind an explicit permission prompt
  of our own first. Result is held in memory for the session.
- Fallback when the user declines or the browser fails: a saved home city,
  chosen once through a small form and stored in `localStorage` (no account
  exists; task [009](009-users-and-api-keys.md) is separate).
- What is sent to the backend: rounded coordinates (2 decimals, about 1 km) as
  query parameters on the card endpoint, or the saved city's Wikidata id. No
  raw precise location, nothing stored server-side, nothing logged: the
  backend must not log those parameters.
- Privacy note in the UI next to the prompt: the location goes to our server
  and to Open-Meteo, and is not stored.
- The backend accepts coordinates in place of an entity for the weather
  provider only, using the task 033 provider.

## Acceptance criteria

- Frontend tests with a mocked geolocation: granted, denied (falls back to
  the home city), and no home city (shows the form).
- A backend test shows coordinates are rounded and not present in log output.
- `make check-quiet` passes.

## Out of scope

Location for any other query type, IP geolocation, user accounts.
