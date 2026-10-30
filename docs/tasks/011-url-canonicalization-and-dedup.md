# 011. URL canonicalization and duplicate detection

- Status: open
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
