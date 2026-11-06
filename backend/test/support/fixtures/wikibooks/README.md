# Wikibooks fixtures

Recorded responses of the MediaWiki Action API (`https://en.wikibooks.org/w/api.php`, `format=json`, `formatversion=2`), captured on 2026-11-06 for the tests of `Knowseek.Discovery.Sources.Wikibooks`, with the requests that source sends.

| File | Request pattern |
| --- | --- |
| `search.json` | `action=query&list=search&srsearch=how do i fix a flat tire&srlimit=2&srnamespace=0`, plus a third result added by hand: *Tomos Moped/Printable version* (page 448201), so the tests also see a print version |
| `page_3567.json`, `page_12404.json` | `action=query&prop=extracts\|info\|pageprops\|pageviews\|revisions\|templates&rvprop=timestamp&explaintext=1&inprop=url&pvipdays=60&tlnamespace=0&tllimit=2&pageids=<id>` (recorded without `templates`; these pages transclude no main-namespace page, so the answer is the same) |
| `page_448201.json` | The same request with `templates`. The page is `{{Printable}}`, which transcludes the book's chapters: `templates` lists two of them and `continue` says there are more |
| `search_cookbook.json` | `action=query&list=search&srsearch=cook eggs&srlimit=3&srnamespace=102&srprop=` (the Cookbook namespace), cut by hand to its first result, *Cookbook:Hard Cooked Eggs* (page 123791), with `sroffset` set to match |
| `search_cookbook_none.json` | The same request for `srsearch=fix a flat tire`: no Cookbook page matches |
| `page_123791.json` | The page request above with `templates` for the recipe *Cookbook:Hard Cooked Eggs* (namespace 102). It transcludes no main-namespace page, so the answer has no `templates` |

The `extract` fields are cut to their first paragraphs (about 1,300 characters; the recipe up to its "Steaming method" section) to keep the files small; everything else is as recorded, except where the table says so. The `lastrevid` field in each file identifies the page revision.

## License and attribution

The page text (the `extract` fields) is from Wikibooks and is available under the [Creative Commons Attribution-ShareAlike 4.0 license](https://creativecommons.org/licenses/by-sa/4.0/) (CC BY-SA 4.0). It is shortened here. It is not covered by this repository's AGPL-3.0 license. Authors are credited in each page history:

| Page | Page history |
| --- | --- |
| Bicycles/Maintenance and Repair/Wheels and Tires/Fixing a flat | <https://en.wikibooks.org/w/index.php?title=Bicycles/Maintenance_and_Repair/Wheels_and_Tires/Fixing_a_flat&action=history> |
| Tomos Moped/Repair | <https://en.wikibooks.org/w/index.php?title=Tomos_Moped/Repair&action=history> |
| Tomos Moped/Printable version | <https://en.wikibooks.org/w/index.php?title=Tomos_Moped/Printable_version&action=history> |
| Cookbook:Hard Cooked Eggs | <https://en.wikibooks.org/w/index.php?title=Cookbook:Hard_Cooked_Eggs&action=history> |
