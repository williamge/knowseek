# 032. Company card

- Status: done
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

## Outcome

Built. [ADR 0021](../decisions/0021-company-card-source.md) has the evidence.

**Source (the first step).** Re-probed on 2026-10-31: the Yahoo chart
endpoint returned HTTP 429 on 3 of 3 requests, so previous close, market state
and timestamps are still unseen there. The keyless alternatives that answer
(Nasdaq's quote API, Cboe's delayed-quote JSON) are forbidden for automated
use by their own words (Nasdaq's `robots.txt` disallows everyone but Google
and Bing, and its legal page bars "any process, whether automated or manual, to
capture data"; Cboe: "STRICTLY PROHIBITED TO DOWNLOAD DELAYED QUOTE TABLE DATA
... BY USING AUTO-EXTRACTION PROGRAMS"), and Stooq answers a plain client with
a JavaScript challenge. So the keyed fallback was built, as the task said to do
only then: **Twelve Data** `/quote`, behind `Knowseek.Cards.Provider`, with
`TWELVEDATA_API_KEY` optional (no key gives `none`).

**Built.** `Knowseek.Cards.TwelveData` (client, key in the `Authorization`
header) and `Knowseek.Cards.Providers.TwelveDataCompany`: Nasdaq and NYSE only
(first supported listing in `exchange_tickers`), card type `company` with
symbol, exchange, price, change and percent change against the previous close,
currency, market state, the quote's own time and a `delayed` flag. TTL 60 s
open; closed, until two minutes before the next regular open (DST computed, no
holiday calendar), capped at an hour. A 429 (also in a 200 body), a rejected
key or a malformed body goes through the framework to `stale` or
`unavailable`. The frontend has `CompanyFacts.tsx` (price, signed change in
the existing `--good`/`--accent` colours, market state, delayed label, quote
time) and one dispatch line plus a footer line in `FactCard.tsx`. README API
table and variable table, ARCHITECTURE, `.env.example`, the fixtures README and
the "three checks" wording (AGENTS.md, ADR 0010 update, ADR 0020) are done.

**Left out.** `pre_market` and `after_hours` are never reported: Twelve Data's
`/quote` gives a boolean, extended-hours prices are a paid feature. The
frontend type and labels allow them. No holiday calendar. Other exchanges and
charts, as the task said.

**Unverified.** The `demo` key answers for `AAPL` only, so no Twelve Data body
for `NVDA` was ever seen; the NVDA and open-market fixtures are derived (see
`backend/test/support/fixtures/twelvedata/README.md`), and real-network smoke
tests ran for `aapl`/`apple`. The free key's terms allow internal,
non-display use only.

**Follow-ups.** [040](040-company-card-display-license.md): decide the licence
(or another source) for a public deployment, report extended-hours states,
record a real NVDA body.
