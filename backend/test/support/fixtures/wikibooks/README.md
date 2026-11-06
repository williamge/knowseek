# Wikibooks fixtures

Recorded responses of the MediaWiki Action API (`https://en.wikibooks.org/w/api.php`, `format=json`, `formatversion=2`), captured on 2026-11-06 for the tests of `Knowseek.Discovery.Sources.Wikibooks`, with the requests that source sends.

| File | Request pattern |
| --- | --- |
| `search.json` | `action=query&list=search&srsearch=how do i fix a flat tire&srlimit=2&srnamespace=0` |
| `page_3567.json`, `page_12404.json` | `action=query&prop=extracts\|info\|pageprops\|pageviews\|revisions&rvprop=timestamp&explaintext=1&inprop=url&pvipdays=60&pageids=<id>` |

The `extract` fields are cut to their first paragraphs (about 1,300 characters) to keep the files small; everything else is as recorded. The `lastrevid` field in each file identifies the page revision.

## License and attribution

The page text (the `extract` fields) is from Wikibooks and is available under the [Creative Commons Attribution-ShareAlike 4.0 license](https://creativecommons.org/licenses/by-sa/4.0/) (CC BY-SA 4.0). It is shortened here. It is not covered by this repository's AGPL-3.0 license. Authors are credited in each page history:

| Page | Page history |
| --- | --- |
| Bicycles/Maintenance and Repair/Wheels and Tires/Fixing a flat | <https://en.wikibooks.org/w/index.php?title=Bicycles/Maintenance_and_Repair/Wheels_and_Tires/Fixing_a_flat&action=history> |
| Tomos Moped/Repair | <https://en.wikibooks.org/w/index.php?title=Tomos_Moped/Repair&action=history> |
