# 040. Company card: a quote source that may be displayed

- Status: open
- Area: `Knowseek.Cards.Providers.TwelveDataCompany`, docs
- Depends on: 032

## Goal

Decide, and build, how the company card may legally be shown to people other
than the person running Knowseek. [ADR 0021](../decisions/0021-company-card-source.md)
found no keyless quote source whose terms allow automated use, and
Twelve Data's free key allows internal, non-display use only.

## Scope

- Owner decision: buy a plan that allows display (Twelve Data "Grow"), switch
  to another source whose terms allow it (a second provider module behind
  `Knowseek.Cards.Provider`; Finnhub reports pre-market and after-hours
  sessions but its free plan forbids sharing), or keep the card for personal
  instances and say so in the README (already done).
- If a source reports extended-hours sessions, report `pre_market` and
  `after_hours` (the frontend type and labels exist) and give them a TTL of a
  few minutes.
- First run with a real Twelve Data key against `NVDA` and `JPM`: check that
  the recorded `AAPL` shape is the shape of every symbol, and replace the
  composed `quote_nvda_closed.json` fixture with a recording.

## Acceptance criteria

- The README and ADR 0021 state which licence a public deployment needs.
- If a provider is added, it has fixtures recorded from real responses.
- `make check-quiet` passes.
