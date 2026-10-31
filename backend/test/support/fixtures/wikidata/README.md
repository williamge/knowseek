# Wikidata fixtures

Recorded responses of the Wikidata API (`https://www.wikidata.org/w/api.php`, `format=json`), captured in October 2026 for the tests of `Knowseek.Entities.Wikidata`. One pair per query: apple, japan, knicks, nvda, nvidia, texas, tokyo.

| File | Request pattern |
| --- | --- |
| `search_<query>.json` | `action=wbsearchentities&search=<query>&language=en&uselang=en&type=item` |
| `entities_<query>.json` | `action=wbgetentities&ids=<Q-ids from the search>&props=claims|sitelinks` |

## License

Wikidata structured data is available under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) (public domain dedication). Attribution is not required. The files are kept as recorded.
