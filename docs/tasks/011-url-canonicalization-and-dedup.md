# 011. URL canonicalization and duplicate detection

- Status: done
- Area: `Knowseek.Documents`
- Depends on: none

## Goal

Stop the same content from being indexed many times under different URLs.

## Scope

- Canonicalize URLs before ingest: lowercase scheme and host, drop fragments,
  drop tracking parameters (`utm_*`, `fbclid`, ...), sort query parameters,
  strip default ports.
- Exact duplicate detection: if a different URL has the same `content_hash`,
  record it as an alias of the existing document instead of a new document.
- Optional: near-duplicate detection (for example SimHash). If you skip it,
  write a follow-up task.

## Acceptance criteria

- Unit tests for canonicalization rules.
- Ingesting the same body under two URLs gives one document.

## Outcome

Built (see `docs/decisions/0013-url-canonicalization-and-aliases.md`):

- `Knowseek.Documents.URL`: pure canonicalization (lowercase scheme and host,
  no fragment, no default port, no tracking parameters, sorted query). The
  tracking list is in that module. `Document.ingest_changeset/2` applies it.
- `document_aliases` table and `Knowseek.Documents.DocumentAlias`. `ingest/1`
  matches by URL or alias, then by `content_hash`, and records the alias.
  Bodies shorter than 200 characters are not merged by hash.
  `documents.content_hash` is indexed.
- Tests for the canonicalization rules and the ingest flow.

Left out: no migration that rewrites or merges stored URLs, and no
near-duplicate detection. Both are in
[022](022-backfill-urls-and-near-duplicates.md).
