# Twelve Data fixtures

Bodies of Twelve Data's `/quote` endpoint (`https://api.twelvedata.com/quote?symbol=<symbol>&exchange=NASDAQ`, header `Authorization: apikey <key>`) for the tests of `Knowseek.Cards.Providers.TwelveDataCompany`. They hold factual quote data only (prices, volumes, a company name). Some are recorded, some are derived; the table says which, so that a test does not claim more than the file is.

| File | Origin | Contents |
| --- | --- | --- |
| `quote_aapl_closed.json` | **Recorded** on 2026-10-31 with the `demo` key (it answers for `AAPL` only). Pretty-printed, otherwise byte for byte. | Apple after the close of Friday 2026-10-30: `close` 344.63, `previous_close` 348.91, `change` -4.28, `percent_change` -1.22668, `is_market_open: false`, `timestamp` (start of the session's bar) and `last_quote_at` (the quote's own time). The numbers are strings, as Twelve Data sends them. |
| `error_401_demo.json` | **Recorded** the same day: `NVDA` with the `demo` key. | The 401 body (`code`, `message`, `status: "error"`) that Twelve Data sends for a rejected key. |
| `quote_aapl_open.json` | **Derived** from `quote_aapl_closed.json`: `is_market_open: true`, prices and `last_quote_at` changed to a plausible session value (a positive change). Not recorded: the markets were closed when the fixtures were made, so no real open-market body could be captured. Same field names and types as the recorded body. | An open-market quote with a positive change. |
| `quote_nvda_closed.json` | **Composed** in the shape of `quote_aapl_closed.json`, with Nvidia's close of 2026-10-30 read from three other quote pages on 2026-10-31 (204.64, previous close 213.66, change -9.02, -4.22%). The `demo` key does not answer for `NVDA`, so Twelve Data's own body for it was never seen. | A closed-market quote with a negative change for the `nvda`/`nvidia` query tests. |
| `error_429.json` | **Composed** from Twelve Data's documented per-minute credit error (`code` 429, `status: "error"`); the message wording is paraphrased. A 429 was never provoked. | The body of a rate-limited answer. |

If a test needs a shape that none of these has, add a file and a row here rather than building a body in the test.

## License

Twelve Data's terms restrict redistribution of its data. The files hold a handful of quote values for tests and are not a data feed; the application calls the API at run time and does not redistribute it. See `docs/decisions/0021-company-card-source.md`.
