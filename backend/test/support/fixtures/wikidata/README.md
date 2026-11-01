# Wikidata fixtures

Recorded responses of the Wikidata API (`https://www.wikidata.org/w/api.php`, `format=json`), captured in October 2026 for the tests of `Knowseek.Entities.Wikidata`. One pair per query: apple, cambridge, georgia, japan, knicks, london, new york (`new_york`), nvda, nvidia, texas, tokyo, washington.

| File | Request pattern |
| --- | --- |
| `search_<query>.json` | `action=wbsearchentities&search=<query>&language=en&uselang=en&type=item` |
| `entities_<query>.json` | `action=wbgetentities&ids=<Q-ids from the search>&props=claims|sitelinks` |

`entities_knicks.json` has one hand-added claim on two items, copied from the live API on 2026-10-31 (task 031, which reads `P118`, league): `P118` = `Q155223` (NBA) on the New York Knicks (`Q131364`) and `P118` = `Q842793` (NBA G League) on the Westchester Knicks (`Q15927936`). Both claims are trimmed to the fields the resolver reads, like the rest of the file.

`search_{new_york,washington,london,georgia,cambridge}.json` and `entities_*` of the same names were recorded on 2026-11-01 (task 033, the choice of place for the weather intent): read-only `wbsearchentities` (`limit=20`, first 8 hits kept) and one `wbgetentities` per search, 2 s apart, with a descriptive User-Agent. The claims are trimmed to `P31` and `P625`; sitelinks are trimmed like the others (the `enwiki` entry is real, the rest are empty placeholders that keep the count). `entities_new_york.json` holds, for example, New York state (247 sitelinks) and New York City (325): the sitelink counts are what the weather rule compares.

## License

Wikidata structured data is available under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) (public domain dedication). Attribution is not required. The files are kept as recorded, except for the claims named above.
