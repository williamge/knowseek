# Wikipedia fixtures

Recorded responses of the MediaWiki Action API (`https://en.wikipedia.org/w/api.php`, `format=json`, `formatversion=2`), captured in October 2026 for the tests of `Knowseek.Discovery.Sources.Wikipedia`. The recording date is the date of the commit that added the files; the `touched` and `lastrevid` fields inside each file identify the article revision.

| File | Request pattern |
| --- | --- |
| `search.json` | `action=query&list=search&srsearch=<query>` |
| `page_19007.json`, `page_74020014.json`, `page_76162223.json` | `action=query&prop=extracts\|info\|pageprops&explaintext=1&pageids=<id>` |
| `page_missing.json`, `error_missingparam.json` | error and missing-page shapes |

The two non-disambiguation pages (`page_74020014.json`, `page_76162223.json`) also carry the `revisions` field (`prop=revisions&rvprop=timestamp`) that the source requests. It was added to the recorded files from a live call on 2026-10-31 for the same page ids, whose `lastrevid` matched the recorded one, so the timestamp belongs to the recorded revision. `page_19007.json` (a disambiguation page) has no `revisions` field.

## License and attribution

The article text (the `extract` fields) is from Wikipedia and is available under the [Creative Commons Attribution-ShareAlike 4.0 license](https://creativecommons.org/licenses/by-sa/4.0/) (CC BY-SA 4.0). It is not covered by this repository's AGPL-3.0 license. Authors are credited in each page history:

| Article | Page history |
| --- | --- |
| Mercury | <https://en.wikipedia.org/w/index.php?title=Mercury&action=history> |
| Vector database | <https://en.wikipedia.org/w/index.php?title=Vector_database&action=history> |
| Hierarchical navigable small world | <https://en.wikipedia.org/w/index.php?title=Hierarchical_navigable_small_world&action=history> |

The files are kept as recorded. `search.json` lists only page ids and titles.
