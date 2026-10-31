# 032. Company card

- Status: open
- Area: `Knowseek.Cards` (new provider), web card rendering
- Depends on: 031

## Goal

Show a price card for a public company ("nvda", "nvidia").

## Scope

- Provider using a Yahoo-style chart endpoint
  (`/v8/finance/chart/<symbol>`) with a browser User-Agent set in config.
  Unofficial: failures are expected, handled by the framework's stale or
  unavailable status.
- Symbol: from the entity's `exchange_tickers` (Wikidata P414 with the P249
  qualifier; Nvidia: Nasdaq, "NVDA"). Query `nvda` resolves through task 030's
  type filtering to Nvidia, not to the screen reader. For a non-US exchange the
  Yahoo suffix mapping is not probed; support only Nasdaq and NYSE first and
  return `:none` for other exchanges.
- First step: re-probe the chart endpoint. In the design session it returned
  HTTP 429 for every attempt, so previous close, market state and timestamps
  are unverified. Record the real field list in this file's Outcome before
  coding the mapping.
- Fields: price, change against previous close, market state, and the quote
  time as `as_of`.
- TTL depends on market state: a few minutes while open, until the next open
  (capped at hours) when closed.
- Label quotes as possibly delayed and name the source in the card.
- Keyed fallback (Finnhub or Alpha Vantage) is documented in the ADR/ARCHITECTURE
  notes and the provider behaviour allows it, but is not built here.

## Acceptance criteria

- `Req.Test` stubs with a chart fixture in `backend/test/support/fixtures.ex`;
  no network.
- NVDA entity gives a card with price, change and `as_of`; open and closed
  fixtures give different TTLs.
- A 429 or malformed body gives `stale` or `unavailable`, not an error.
- Frontend shows the delayed-quote label.
- `make check-quiet` passes.

## Out of scope

The keyed fallback provider, charts, other exchanges, crypto.
