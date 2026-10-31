# 022. Merge stored duplicate URLs and detect near-duplicates

- Status: open
- Area: `Knowseek.Documents`, migration
- Depends on: 011

## Goal

Task 011 canonicalizes URLs and merges exact duplicates at ingest. Two gaps
remain. Documents stored before it keep their old URLs, and pages that differ
by a few characters are still separate documents.

## Scope

- Backfill: find stored documents whose URLs canonicalize
  (`Knowseek.Documents.URL`) to the same value, and documents that share a
  `content_hash` (long enough, see `Documents.min_alias_body_length/0`). Keep
  the oldest document of each group. Record the other URLs as aliases
  (`document_aliases`) and delete the other documents (chunks cascade).
  Rewrite the kept document's `url` to its canonical form, unless that URL
  belongs to another document.
- Run it as a mix task or an Oban job that can be re-run, not as a migration
  that depends on application code. Report how many groups it merged.
  Documents the ingest path races created (same body, different new URLs) are
  in scope.
- Optional: near-duplicate detection, for example SimHash of the body stored
  in a column and compared by Hamming distance. Decide the distance at which
  documents merge, measure false positives on real data, and write an ADR
  (it supersedes the exact-hash rule in 0013 or extends it).
- Clean up documents that share a body but were not merged, because a known
  URL wins over a hash match at ingest (see "Consequences" in ADR 0013).
- Optional: unify host spellings that canonicalization leaves apart:
  internationalized names (Unicode and punycode) and a trailing dot.

## Acceptance criteria

- A test builds documents with non-canonical URLs and with the same body under
  several URLs, runs the backfill, and checks that one document is left per
  group, with the other URLs as aliases and the search returning one hit.
- Running the backfill twice changes nothing.
- If near-duplicate detection is built: tests show that a body with a small
  edit merges and an unrelated body does not.
