# 040. Company price card

- Status: parked (no source of quotes that may be used, ADR 0021)
- Area: `Knowseek.Cards.Providers.Company`, web card rendering
- Depends on: 032

## Goal

Show a delayed stock price on the company card ("nvda": last price, change
against the previous close, market state).

## Why it is parked

Price data is out of scope of task 032 ([ADR 0021](../decisions/0021-company-card-source.md)):
no source of quotes was found that a self-hosted, open-source project may use
without a key and a licence. Do not start this task until one exists. The
options that were researched, and what stops each, are in ADR 0021:

- Keyless: Nasdaq's quote API and Cboe's delayed-quote JSON (their own words
  forbid automated access), Yahoo's chart endpoint (works with a descriptive
  User-Agent today, but Yahoo's terms forbid automated access), Stooq
  (a proof-of-work page), CNBC (`robots.txt` disallows everything).
- Keyed: Twelve Data, Finnhub, Massive (Polygon), Financial Modeling Prep,
  Tiingo (free plans do not allow displaying the data, or only to its owner),
  Alpha Vantage (its terms allow personal display, 25 requests a day, end of
  day only; the closest fit).

## Scope, if unblocked

- A price source behind a small behaviour of its own, off unless the operator
  configures it; the company provider adds a `price` block when it succeeds and
  shows "price unavailable" when it fails, with the SEC facts always shown.
- TTL by market state (open about a minute, closed until shortly before the next
  open, capped), an honest "delayed" label, and a source credit.
- Extended-hours states only if the source reports them.

## Acceptance criteria

- The source's terms allow the use, quoted in an ADR.
- Fixtures are recorded from real responses.
- `make check-quiet` passes.
