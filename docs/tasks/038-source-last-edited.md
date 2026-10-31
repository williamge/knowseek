# 038. Show when the source says a page was last edited

- Status: done
- Area: `Knowseek.Discovery.Sources.Wikipedia`, `Knowseek.Documents`, `Knowseek.Search`, frontend hit card
- Depends on: none

## Goal

Hit cards say "fetched just now", which is when Knowseek saw the page, not how old the content is. Show when the source says the page was last edited.

## Design note

- A nullable `documents.source_updated_at` (`utc_datetime`). It is not `published_at` (first published; null for Wikipedia today) and not `fetched_at` (when we last saw the content).
- Wikipedia: the timestamp of the latest **revision** (`prop=revisions&rvprop=timestamp`), requested in the same call as the text and page views. No extra request per page. `touched` is not used: it also moves when a template changes.
- Written only by `Documents.ingest/1` (rule 2). A candidate without the value leaves the stored one alone (same rule as `monthly_views`).
- An ingest of an unchanged body still updates it. The revision time can change while our plain-text extract is identical (only a template or a table changed). The field means "the source says last edited", not "our text changed", so following the source is right.
- No re-fetch mechanism. The owner decided to revisit it when a source needs it. A stored value is as old as our last fetch of that page.
- API: `source_updated_at` on every search hit and in the document JSON (`null` when unknown). UI: next to "fetched ...", the hit card shows "edited Oct 29" (with the year when it is not this year) only when the field is present.

## Outcome

Verified by live call on 2026-10-31 (`generator=search&gsrsearch=knicks&prop=revisions|info&rvprop=timestamp`, several pages in one query without `rvlimit`): New York Knicks revision `2026-10-29T03:01:48Z`, `touched` `2026-10-30T03:48:17Z`; Westchester Knicks revision `2026-10-04T06:15:30Z`, `touched` `2026-10-30T05:45:59Z`. So `touched` is later than the last edit, and the revision timestamp is the right field.

Built: migration, schema field, ingest (cast, same rules as `monthly_views`), the Wikipedia source (`revision_time/1`), the field on `Search.Hit`, the search and document JSON, `frontend/src/types.ts`, the hit card line, tests (source, ingest, search, JSON, frontend), fixtures with a `revisions` field (see the fixtures README), README API table and `docs/ARCHITECTURE.md`. Corrected the Knicks "a season old" statement in task 028 and ADR 0017.

Left out: showing the date in the document reader and in the recent-documents list; a re-fetch mechanism; other sources (none have the value yet).

Smoke (own server on port 4300, real Wikipedia source, hashing embeddings, worktree database): `POST /api/search {"query":"knicks"}` returned New York Knicks `2026-10-29T03:01:48Z`, Westchester Knicks `2026-10-04T06:15:30Z` and 2025-26 New York Knicks season `2026-10-26T05:00:53Z`, equal to the revision timestamps that the Wikipedia API returned for the same titles.
