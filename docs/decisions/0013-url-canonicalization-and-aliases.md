# 0013. Canonical URLs and aliases for exact duplicate content

- Status: Accepted
- Date: 2026-10-30

## Context

The URL is a document's identity. The same page reached through
`https://Example.com/a?utm_source=x#top` and `https://example.com/a` became two
documents, with two sets of chunks, and both showed up in search. The same
article served from a mirror or a syndication URL did too.

## Decision

**Canonical URLs.** `Knowseek.Documents.URL.canonicalize/1` (pure) runs on
every `url` in `Document.ingest_changeset/2`. For `http` and `https` it
lowercases scheme and host, drops the fragment, drops the default port, gives
an empty path `/`, drops tracking parameters, and sorts the remaining query
parameters. It does not decode or re-encode anything. The tracking list
(`utm_*`, `fbclid`, `gclid`, `mc_cid`, `mc_eid`, and a few more) is in that
module only. Other URLs (`urn:knowseek:sha256:...`, other schemes) are only
trimmed.

**Aliases.** A new table `document_aliases` (`url` unique, `document_id` with
`on delete cascade`) holds other canonical URLs of a document. It does not
reference `documents.url`, so a document keeps its own URL. `Documents.ingest/1`
stays the only writer. It picks the document in this order:

1. the document whose `url` equals the canonical URL. A changed body updates
   it (and re-embeds).
2. else the document that has the canonical URL as an alias. If the body is
   the same, only `fetched_at` moves. If the body differs, the URL no longer
   serves a copy: the alias row is deleted and the URL goes through steps 3
   and 4 as if it were new.
3. else, if the body is at least `Documents.min_alias_body_length/0` (200)
   characters after trimming, the oldest document with the same
   `content_hash`. Only its `fetched_at` moves: the fields of the copy
   (`source`, `title`, `metadata`, `published_at`) never overwrite the
   original's. The canonical URL is recorded as an alias, in one transaction
   with the `fetched_at` update, and the existing document is returned. No
   chunks are written, so no embedding call is made. If the document has
   only a URL generated from the body (`urn:knowseek:sha256:...`) and the
   incoming URL is a real one, the real URL becomes the document's `url`
   and there is no alias.
4. else a new document.

An incoming URL generated from the body is never recorded as an alias: the
body already implies it. Embedding stays outside transactions.
`documents.content_hash` gets a plain index for the lookup.

**Races.** Two ingests of one new URL: the insert on `documents.url` is an
upsert, as before. Two ingests of one new alias URL: the alias insert is
`ON CONFLICT (url) DO NOTHING` (`documents_concurrency_test.exs`). If the
body-only document adopts a real URL that a concurrent ingest took first, the
URL is recorded as an alias instead. Taking the oldest document by hash makes
concurrent copies merge into the same one.

**Short bodies.** "Page not found", a cookie notice, or a one-line stub
repeats across unrelated URLs. Matching on the hash alone would merge them.
Below 200 characters, only the URL decides. 200 is a guess, not a measurement.

## Consequences

- One page gives one document, one set of chunks, and one hit in search.
- The match is by exact SHA-256 of the body. A page with a changing date, an
  ad block, or a view counter has a new hash each fetch and is not merged. This
  needs near-duplicate detection, which is not built.
- A long body can still be a false positive: boilerplate pages that are long
  and the same on every URL (a site-wide notice, a login wall). Raise the floor
  or add a check if this shows up.
- A URL that is an alias and later serves a different body becomes its own
  document. The original keeps its body, so fetching either URL does not flip
  the other.
- A known URL (step 1 or 2) wins over a hash match. If a document's body
  changes to equal another document's body, two documents with the same body
  remain. The same happens when an alias is dropped and the new body matches
  nothing. Task 022 cleans these up.
- Two simultaneous ingests of one body under two different new URLs can both
  insert, since there is no unique constraint on the hash. The duplicates
  merge only when a later ingest finds the oldest one. A backfill would clean
  them up.
- URLs already stored are not rewritten or merged. A stored non-canonical URL
  is not matched by its canonical form, so re-ingesting it creates a new
  document. Task 022 covers the backfill and near-duplicate detection.
- The canonical form can differ from what a server wants: some sites use the
  fragment, or a parameter on the tracking list, to pick content. The list is
  short and in one place.
- Hosts are only lowercased. Internationalized names in Unicode and punycode
  form (`münchen.de` and `xn--mnchen-3ya.de`) and a trailing dot
  (`example.com.`) are not unified, so those variants stay separate documents
  unless their bodies match.
