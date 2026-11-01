# 0021. Company card: Twelve Data, keyed and optional

- Status: Accepted
- Date: 2026-10-31

Related: [0017](0017-live-fact-cards.md) (live fact cards; decision 3 listed a
Yahoo-style chart endpoint with a keyed fallback), task
[032](../tasks/032-company-card.md).

## Context

The company card shows the stock price of "nvda" or "nvidia". It needs a
last price, the previous close (for the change), the market state, the quote's
own time, and whether the quote is delayed, for US-listed symbols. ADR 0017
preferred a keyless source and named a keyed provider as the fallback. The
owner had not decided; the default was "no secrets required to run the project".

On 2026-10-31 (a Saturday, the markets closed after Friday 2026-10-30) every
candidate was probed with `curl`, a few requests each, spaced. Terms were read
on the vendor's own pages.

## Probe results

| Source | Works from a script? | Fields | Rate-limit behaviour | Terms |
| --- | --- | --- | --- | --- |
| Yahoo chart, `query1.finance.yahoo.com/v8/finance/chart/NVDA?range=1d&interval=1d` (browser User-Agent) | **No.** HTTP 429 `Too Many Requests` on 3 of 3 attempts, 4 s apart (the design session got one price and 429s on every other try). | Not seen this time. | 429 with no `Retry-After`, from the first request. | The only Yahoo API terms page found, the Developer API Terms (`policies.yahoo.com/.../apiforydn`), covers the YDN API keys, not this endpoint: "You SHALL NOT create any script or other automated tool that attempts to create multiple API Keys." The chart endpoint has no published terms of its own. |
| Nasdaq quote API, `api.nasdaq.com/api/quote/NVDA/info?assetclass=stocks` (browser User-Agent; plain `curl` is refused at the HTTP/2 layer) | Yes: 200 on 20 of 20 requests in a row, no throttling seen. | `lastSalePrice` (`"$204.64"`), `netChange`, `percentageChange`, `lastTradeTimestamp` (`"Oct 30, 2026"`, a date), `isRealTime` (false), `marketStatus` (`"Closed"`), `currency` (`null`). All values are formatted strings. An unknown symbol is `rCode` 400. | None seen. | **Forbidden.** `https://api.nasdaq.com/robots.txt` is `User-agent: *` / `Disallow: /` (only Googlebot and Bingbot are allowed). The Nasdaq legal page (`nasdaq.com/legal`) says: "Not access or use the Service, or any process, whether automated or manual, to capture data or content from the Service or circumvent any mechanisms for preventing the unauthorized reproduction or distribution of the Service for any reason". |
| Cboe delayed quotes, `cdn.cboe.com/api/global/delayed_quotes/quotes/NVDA.json` (no User-Agent needed; 307 to `cdn-api.cboe.com`) | Yes: 200 on 30 of 30 in a row, CDN-cached (`s-maxage=5`). | `current_price`, `price_change`, `prev_day_close`, `last_trade_time`, a generation `timestamp`. No market state, no currency, no name. `price_change` was the last session's change while `current_price` was a later quote (205.25 against the close of 204.64), so the pair is inconsistent. An unknown symbol is HTTP 403. | None seen. | **Forbidden.** The page that uses it (`cboe.com/delayed_quotes/nvda/quote`) says: "PLEASE NOTE: IT IS STRICTLY PROHIBITED TO DOWNLOAD DELAYED QUOTE TABLE DATA FROM THIS WEB SITE BY USING AUTO-EXTRACTION PROGRAMS/QUERIES AND/OR SOFTWARE." |
| CNBC quote service, `quote.cnbc.com/quote-html-webservice/restQuote/symbolType/symbol?symbols=NVDA&output=json` | Yes: 200. Has `last`, `change`, `change_pct`, `previous_day_closing`, `curmktstatus` (`POST_MKT`), `last_time`, `realTime`. | Complete. | Not tested beyond one request. | Not read and not pursued: a media company's undocumented website back end, with no published API terms, is the same situation as Nasdaq's and Yahoo's. |
| Stooq, `stooq.com/q/l/?s=nvda.us&f=sd2t2ohlcv&h&e=csv` | **No.** The page answered with a JavaScript proof-of-work challenge ("This site requires JavaScript to verify your browser", then `POST /__verify`). A plain HTTP client gets no data. | None. | n/a | `robots.txt` is 96 bytes and was not fetched in full; no terms were read, since the endpoint is unusable from a server. |
| Twelve Data `/quote` (keyed) | Yes, with a key. The shared `demo` key answers for `AAPL` only (HTTP 401 for anything else). | `symbol`, `name`, `exchange`, `currency`, `close`, `previous_close`, `change`, `percent_change`, `is_market_open`, `timestamp`, `last_quote_at`, volume, 52-week range. Numbers are strings. Documented as real-time for US stocks and ETFs. | Free plan: 8 requests a minute, 800 a day ("API credits reset each minute"); HTTP 429 with the same error JSON shape. | Free ("Basic") plan: "Internal non-display usage. Data may be used internally for testing, evaluation, or development purposes only. The data cannot be displayed to users, shared externally, or used in production systems." The terms also forbid to "Use Free Tier data for commercial purposes". Displaying data to others needs a paid plan ("Grow", $79 a month, "for hobby projects"). |
| Finnhub (keyed) | Not probed beyond HTTP 401 `Invalid API key` (no key). Per its public documentation, not exercised here: `/quote` (`c`, `d`, `dp`, `pc`, `t`) and `/stock/market-status?exchange=US` (`session`: pre-market, regular, post-market). | Would give pre-market and after-hours states. | Free: 60 requests a minute, per its documentation (not verified). | "All plan listed on Finnhub website is strictly for personal use unless explicitly stated otherwise." and "You hereby agree to not redistribute or share access to data or derived results from the data obtained from Finnhub with anyone or any 3rd party without written approval from Finnhub." |
| Alpha Vantage (keyed) | `GLOBAL_QUOTE` works with the `demo` key for `IBM` only. | Price, previous close, change, latest trading day; no market state, no quote time. | Free: 25 requests a day. | Its terms page could not be read (compressed body). Not chosen: 25 a day is too little for even one card at a 60 s TTL. |

## Decision

**No keyless source is usable for this project.** Yahoo throttles every
request; Stooq needs a browser; Nasdaq and Cboe work but their own words
forbid automated access, and Nasdaq's `robots.txt` disallows everyone but two
search engines. A public AGPL project that ships a client for an endpoint
whose owner forbids it is a bad default, however well the endpoint answers
today. So ADR 0017's fallback applies: a keyed provider, **optional, giving
`none` when no key is set** (the project still runs with no secrets).

**Twelve Data** is the provider, behind `Knowseek.Cards.Provider`
(`Knowseek.Cards.Providers.TwelveDataCompany`, client
`Knowseek.Cards.TwelveData`):

- One request gives every field the card needs (name, currency, previous
  close, change, a market-open boolean, the quote's own time), so a card costs
  one of the 8 requests a minute.
- A real answer could be recorded with its `demo` key (for `AAPL`) and the
  request shape checked against the live API, which keeps the mapping
  honest. Finnhub's would have needed a key first.
- The key goes in the `Authorization: apikey` header, so that it is never in a
  URL or a log line.
- Configuration: `TWELVEDATA_API_KEY` in `config/runtime.exs`,
  `.env.example` and the README variable table. No key: the provider's
  `handles?/1` is false, `Cards.get/2` is `:none`, and nothing is called.

**The licence is the open problem, stated plainly.** Twelve Data's free key
may not be used to display data to users. A person who runs Knowseek for
themselves, on their own machine, is "internal use"; one who serves the card to
other people needs the Grow plan (about $79 a month) or another source. The
README, `.env.example` and the architecture notes say so, and task
[040](../tasks/040-company-card-display-license.md) tracks the decision. Finnhub's free plan has the mirror problem (personal use, no sharing of
derived results), so it is no way out. The owner decides which licence to buy,
if any; until then the card is a feature for a personal instance.

### What the card does and does not claim

- `delayed` is a field of the card, and the UI shows "delayed quote" when it is
  true. Twelve Data documents `/quote` as real-time for US stocks, so the
  provider sends `false`; it never claims real-time on its own, it relays what
  the source says.
- `market_state` is `open` or `closed` only. Twelve Data's `/quote` returns a
  boolean; its pre-market and after-hours prices are a Pro-plan feature
  (`extended_price`, not used). "Closed" therefore includes the extended
  sessions, and the price shown then is the last regular-session close. The
  frontend type already allows `pre_market` and `after_hours`, for a provider
  that reports them (Finnhub's `session` does).
- `quote_time` is `last_quote_at`, the time of the quote, not the fetch time
  (the card's `as_of`). `timestamp` in the body is the start of the day's
  bar, not the quote.

### Entity and symbol

Only Nasdaq (Wikidata `Q82059`, Twelve Data `exchange=NASDAQ`) and the NYSE
(`Q13677`, `NYSE`) are supported: the symbols of other exchanges need
suffixes that were not probed. An entity whose exchanges are all unsupported
is not handled (`none`). An entity with several listings uses the first
supported one in its `exchange_tickers`, which is Wikidata's claim order.

### TTL

Open: 60 s. Closed: until two minutes before the next regular open (Monday to
Friday 09:30 in New York; US daylight saving time is computed, no holiday
calendar), at most an hour and at least a minute. A holiday costs one
refresh at 09:30 that finds the market still closed. A 60 s open TTL uses
about 390 of the 800 daily requests for one company during a 6.5-hour
session; more companies at once exceed the free daily limit and then get
`stale` cards (a 429 is `stale` or `unavailable`, never an error response).

## Consequences

- No new dependency. The client is `Req`, like the ESPN and Wikidata ones.
- A project without a key shows no company cards, by design.
- Tests use `Req.Test` with fixtures in `backend/test/support/fixtures/twelvedata`.
  The README of that directory says which bodies were recorded (AAPL, closed;
  the `demo` key's 401) and which were derived or composed (an open-market
  body, NVDA, a 429). No NVDA body from Twelve Data itself was ever seen,
  because the `demo` key does not answer for it: the mapping for `NVDA` rests
  on the `AAPL` shape, and a first run with a real key is the check.
- If a keyless source with usable terms appears, or the owner buys a plan,
  swapping the provider is one module and one config line.
