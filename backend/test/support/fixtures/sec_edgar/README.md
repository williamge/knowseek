# SEC EDGAR fixtures

Recorded responses of the SEC's EDGAR data API (`https://data.sec.gov`), captured on 2026-11-02 with the User-Agent `Knowseek/0.1 (self-hosted instance)` (the default of `Knowseek.Cards.Edgar`), for the tests of `Knowseek.Cards.Providers.Company` and the card endpoint. Every file is real; none is derived or composed. The content is public filing data (company names, tickers, filing dates and accession numbers, share counts). The SEC allows reuse: "Information presented on sec.gov is considered public information and may be copied or further distributed by users of the web site without the SEC's permission."

| File | Request | Contents |
| --- | --- | --- |
| `submissions_nvda.json` | `/submissions/CIK0001045810.json` | Nvidia. Name, tickers (`NVDA`), exchanges (`Nasdaq`), `sicDescription`, `fiscalYearEnd` (`0131`), `category`. `filings.recent` is trimmed from 1000 entries to 14: the six newest (forms 4, 4/A and 144, which the card must skip) and the eight newest 10-K, 10-Q and 8-K, in the SEC's order, newest first; only the columns the provider reads are kept. |
| `shares_nvda.json` | `/api/xbrl/companyconcept/CIK0001045810/dei/EntityCommonStockSharesOutstanding.json` | Nvidia's shares outstanding, trimmed to the last four reported values (the latest: 24.1 billion at 2026-08-21, from the 10-Q). |
| `submissions_aapl.json`, `shares_aapl.json` | the same for Apple, `CIK0000320193` | Apple (`AAPL`, Nasdaq), trimmed the same way (three non-report forms, the eight newest reports; the last four values). |
| `submissions_googl.json` | the same for Alphabet, `CIK0001652044` | Alphabet: four tickers (`GOOGL`, `GOOG`, `GOOGM`, `GOOGN`) on Nasdaq. |
| `concept_not_found.xml` | the shares concept of Alphabet | The real answer, HTTP 404 with an XML `NoSuchKey` body (`RequestId` and `HostId` removed): Alphabet has several share classes and no non-dimensional `dei:EntityCommonStockSharesOutstanding`, so the card has no shares outstanding. |
| `submissions_tsm.json`, `shares_tsm.json` | the same for Taiwan Semiconductor, `CIK0001046179` | A foreign filer (`TSM` on the NYSE, `TSMWF` over the counter): its reports are 20-F and 6-K, not 10-K, 10-Q and 8-K. |

The trimmed `filings.recent` keeps `accessionNumber`, `filingDate`, `reportDate`, `form`, `items`, `primaryDocument` and `primaryDocDescription` in the SEC's own shape. The Wikidata items that carry the CIK (property `P5531`) are in `../wikidata`.

What the SEC answers to a client it does not like (HTTP 403, an HTML page titled "Undeclared Automated Tool" or "Request Rate Threshold Exceeded") was seen but is not recorded; the tests use a short HTML body of their own for it.

## License

The SEC's reuse statement is quoted above. The files hold factual filing data only; the application calls the API at run time.
