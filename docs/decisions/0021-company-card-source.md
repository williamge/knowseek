# 0021. Company card: facts from SEC EDGAR, price out of scope

- Status: Accepted
- Date: 2026-11-02

Related: [0017](0017-live-fact-cards.md) (live fact cards; decision 3 listed a
Yahoo-style chart endpoint for companies), tasks
032 (done; file removed, see git history) and 040 (parked; file removed, see git history).

## Context

Task 032 was a price card for "nvda": last price, change against the previous
close, market state. It needed a source of delayed quotes for US-listed
symbols that a self-hosted, open-source (AGPL) project can use without secrets,
and whose terms allow it. On 2026-10-31 and 2026-11-02 the candidates were
probed with `curl` (a few requests each, spaced; the first day by the task
agent, the second by a research pass) and their terms were read on the vendors'
own pages. The markets were closed (a weekend), so no intraday body was seen.

## Evidence

Every quotation is from the vendor's page on the day of the probe.

| Source | Does it answer a script? | Terms |
| --- | --- | --- |
| **Nasdaq** quote API (`api.nasdaq.com/api/quote/NVDA/info`) | Yes with a browser User-Agent (200 on 20 of 20); plain `curl` is refused. Fields are formatted strings; the timestamp is a date. | Forbidden. `api.nasdaq.com/robots.txt` is `User-agent: *` / `Disallow: /` (only Googlebot and Bingbot are allowed). The legal page (`nasdaq.com/legal`): "Not access or use the Service, or any process, whether automated or manual, to capture data or content from the Service or circumvent any mechanisms for preventing the unauthorized reproduction or distribution of the Service for any reason". |
| **Cboe** delayed quotes (`cdn.cboe.com/api/global/delayed_quotes/quotes/NVDA.json`) | Yes (200 on 30 of 30). No market state, no currency; `price_change` and `current_price` came from different moments. | Forbidden. The quote page says: "PLEASE NOTE: IT IS STRICTLY PROHIBITED TO DOWNLOAD DELAYED QUOTE TABLE DATA FROM THIS WEB SITE BY USING AUTO-EXTRACTION PROGRAMS/QUERIES AND/OR SOFTWARE." |
| **Yahoo Finance** chart (`query1.finance.yahoo.com/v8/finance/chart/NVDA?range=1d&interval=1d`) | Depends on the User-Agent, not on the rate. HTTP 429 on every request with a full Chrome or Safari string (9 of 9), `curl` (2 of 2), `python-requests` (1 of 1), and on 3 of 3 of the first day's browser-UA requests. HTTP 200 on about 26 of 26 requests with `Mozilla/5.0`, with a descriptive one (`knowseek-selfhosted/0.1 (+https://github.com/williamge/knowseek)`) and with `node-fetch`, 6 to 10 s apart; also 200 for us on 2026-11-02. Fields: `regularMarketPrice`, `chartPreviousClose`, `regularMarketTime`, `currency`, `currentTradingPeriod`; no market state and no delayed flag. | Forbidden. Terms of service, section 2(d)(ix): do not "access or collect data ... using any automated means, devices, programs ... robots, spiders, scrapers ... for any purpose without our express, prior permission"; section 2(e): "you may not access or reuse the Services ... for any commercial purpose". `robots.txt` does not disallow `/v8/finance/chart`; the terms are the obstacle. The answer to a given User-Agent can change without notice. |
| **Twelve Data** `/quote` (free key) | Yes with a key (the `demo` key answers for `AAPL` only). Real-time US quotes, a market-open boolean, `last_quote_at`. 8 requests a minute, 800 a day. | Not for display. The pricing page's Basic plan: "Internal non-display usage. Data may be used internally for testing, evaluation, or development purposes only. The data cannot be displayed to users, shared externally, or used in production systems." The terms forbid to "Use Free Tier data for commercial purposes". |
| **Finnhub** (free key) | 401 without a key; not tested with one. | "You hereby agree to not redistribute or share access to data or derived results from the data obtained from Finnhub with anyone or any 3rd party without written approval from Finnhub." and "All plan listed on Finnhub website is strictly for personal use unless explicitly stated otherwise." |
| **Alpha Vantage** (free key) | `GLOBAL_QUOTE` shape confirmed with the `demo` key (`IBM` only): price, previous close, change, latest trading day; no market state, no time. 25 requests a day; real-time and 15-minute delayed US data is premium. | Terms of service 2(a): "right to install, use, access, display and run the software on any computer or mobile device ... that you own or control, for personal, non-commercial use". The closest fit, and still: 25 requests a day, end-of-day prices, and one key per person. |
| **Massive** (formerly Polygon.io) Basic key | 401 without a key. 5 requests a minute; Stocks Basic is end of day; 15-minute delayed starts at $29 a month. | Market Data Terms: "license to use Market Data exclusively for your personal, non-business, and non-commercial purposes ... you may not use the Market Data to build an application intended for use by end users other than you." |
| **Financial Modeling Prep** (free key) | 401 without a key. 250 requests a day, end of day. | Customers may not "integrate the Data or Services into any tools or applications accessible by any third parties, or use the Services to host, share, display, or provide content for others". |
| **Tiingo** (free key) | 403 without a key. | "All data via the API is for internal consumption only." |
| **CNBC** quote service, **Stooq**, MarketWatch, Google Finance | CNBC answers with a complete quote but its `previous_day_closing` was wrong; Stooq answers a script with a JavaScript proof-of-work page. | `quote.cnbc.com/robots.txt`, `stooq.com/robots.txt` and MarketWatch's are `Disallow: /`. Google Finance: "You agree not to copy, modify, reformat, download, store, reproduce, reprocess, transmit or redistribute any data or information found herein". |

## Decision

**The company card is a facts card from the SEC's EDGAR, with no price.**
Price data is out of scope until a source exists that this project may use
(task 040, parked). The card says what the company is, how many shares it has,
and what it filed last: all public, official and keyless, and the SEC allows
reuse: "Information presented on sec.gov is considered public information and
may be copied or further distributed by users of the web site without the SEC's
permission. Please consider appropriate citation to the SEC as the source." The
card cites it.

Why not ship a price anyway:

- Every source that answers a script without a key has terms that forbid
  automated use (Nasdaq, Cboe, Yahoo, CNBC, Stooq). A public AGPL project that
  ships a client for an endpoint whose owner forbids it is a bad default, even
  if the endpoint answers today (Yahoo does, for a descriptive User-Agent; the
  answer to a User-Agent can change at any time). An opt-in switch does not
  change what the terms say, so none was built.
- Every keyed source that is free forbids showing the data to anyone but its
  owner, or allows it for personal use with a quota too small for a card
  (Alpha Vantage: 25 requests a day).

### What the card holds

`Knowseek.Cards.Providers.Company`, type `company`: legal name, tickers and
exchanges as the SEC lists them, industry (SIC description), fiscal year end,
filer category, shares outstanding with the date of the cover page it comes
from, the latest five 10-K, 10-Q and 8-K (20-F, 40-F and 6-K for a foreign
filer) with links to the documents, and the credit. No revenue: the XBRL tag of
the revenue differs per company and year (`RevenueFromContractWithCustomerExcludingAssessedTax`
stops at FY2022 for Nvidia).

### Identity: the CIK from Wikidata

The SEC Central Index Key is Wikidata property P5531 on the company item
(Nvidia `Q182477`: `0001045810`; Apple `Q312`: `0000320193`). `Knowseek.Entities.Wikidata`
reads it into `Entity.cik` (a ten-digit string; a deprecated claim or another
shape is ignored). An entity with no CIK has no card (`none`). A company also still needs a
Wikidata exchange ticker (P414 with the P249 qualifier) to be of kind
`:company` (`Knowseek.Entities.kind/1`), in addition to the CIK, so an entity with
a CIK but no listed ticker gets `none` too. The SEC's ticker
file (`www.sec.gov/files/company_tickers.json`, 800 KB) is not used: it is on
the host that answered 403 to our default User-Agent (below), and Wikidata
already gives the key.

The card is for any company with a CIK, not only those on Nasdaq or the NYSE
(the first plan): the SEC itself lists the tickers and exchanges, a foreign
filer such as TSMC (a 20-F and 6-K filer, NYSE) has a CIK and a real EDGAR page,
and nothing in the card depends on the exchange.

### Requests, and the SEC's User-Agent

Two requests per card, to `data.sec.gov` only, at most once an hour per company:
`/submissions/CIK<10 digits>.json` and
`/api/xbrl/companyconcept/CIK<10 digits>/dei/EntityCommonStockSharesOutstanding.json`.
The second is optional: a company with several share classes (Alphabet) answers
HTTP 404 (XML `NoSuchKey`) and the card is shown without shares.

The SEC's fair-access rules ask for at most 10 requests a second and for
automated users to declare who they are; "The SEC does not allow 'unclassified'
bots or automated tools to crawl the site." Measured on 2026-11-02, from one
address, 2 to 3 s apart:

| User-Agent | `data.sec.gov` submissions | `www.sec.gov/files/company_tickers.json` |
| --- | --- | --- |
| `Knowseek/0.1 (+https://github.com/williamge/knowseek)` | 403 ("Undeclared Automated Tool") | 403 |
| `Knowseek/0.1 (https://github.com/...; contact@example.com)`, `Knowseek/0.1 github`, `Knowseek/0.1 (github.com/...)` | 403 (any User-Agent that contains `github`) | not tried |
| `Knowseek/0.1 (self-hosted instance)`, `Knowseek/0.1`, `Knowseek/0.1 (+http://example.com)` | **200** | 403 ("Request Rate Threshold Exceeded") |
| `Knowseek local-test noreply@example.com`, any name with an email | 200 | 200 |

The default User-Agent is therefore `Knowseek/0.1 (self-hosted instance)` (no
URL, no `github`), and `SEC_USER_AGENT` replaces it. The SEC asks for a name and
a contact address, so an operator who serves other people should set it; the
default works today and can stop working. When `data.sec.gov` answers 403 or
429 the card goes `stale` (or `unavailable`), all company fetches stop (ten
minutes for a 403, `Retry-After` for a 429) and the log has a warning (about once per block) that
tells the operator to set `SEC_USER_AGENT` with a contact. No retries, no
loops.

### Caching and failure

The framework's cache holds the card for an hour (filings change rarely); a
failed refresh keeps the old card (`stale`). The company provider has its own
cache instance (a rate limit stops all of one cache's fetches), sized like
the weather cache: `max_entries: 500, max_in_flight: 4, reserve_for_refresh: 1`.

## Consequences

- No key, no account and no new dependency. The card works with no
  configuration.
- A company with no Wikidata CIK (rare for a listed US company) has no card.
- The card does not say what a share costs. A reader who wants that follows the
  ticker elsewhere; task 040 is parked until a source with usable terms exists.
- The SEC could block the default User-Agent. The card then degrades to `stale`
  or `unavailable`, and `SEC_USER_AGENT` is the fix.
- The evidence above is the reason the earlier Twelve Data and Yahoo work was
  dropped; neither is in the code.
