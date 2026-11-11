# 0032. Crawl allowlist and the blocked-link log

- Status: Accepted
- Date: 2026-11-11

Related: issues [#88](https://github.com/williamge/knowseek/issues/88) (this
work) and [#89](https://github.com/williamge/knowseek/issues/89) (the crawler
that will call the gate), [0027](0027-wikimedia-concurrency-cap.md) (Wikimedia
cap), [0029](0029-wikibooks-source.md) (shared MediaWiki module),
[0030](0030-sqlite-single-datastore.md) (SQLite).

## Context

Today Knowseek fetches only from the two Wikimedia sites it has a source for.
A crawler (#89) would follow links, and a link can point anywhere. Before any
crawling exists, the owner wants two things: one rule that says which hosts
may ever be fetched, and a record of what the indexed pages link to that the
rule keeps out, so that adding a host to the list is a decision made on
evidence.

## Decision

1. **The allowlist is config, and only the operator changes it.**
   `allowed_hosts` in the `Knowseek.Discovery` config:
   `["en.wikipedia.org", "en.wikibooks.org"]`. There is no suggestion
   mechanism and no editing in the UI. `Knowseek.Discovery.allowed?/1` is the
   one gate: a crawler must call it before it fetches a URL.
2. **Exact host, after `www.` is stripped.** A link is "a web link" when its
   scheme is `http` or `https` and it has a host; anything else (`mailto:`,
   `ftp:`, text) is dropped. Scheme and host are lowercased, the fragment is
   dropped, the rest of the URL is kept byte for byte, and a URL over 2,000
   bytes is dropped. The host loses a leading `www.` and nothing else:
   `en.m.wikipedia.org`, `commons.wikimedia.org` and `de.wikipedia.org` are
   other hosts and are blocked until the operator lists them. That shows which
   Wikimedia sites to consider next. `web.archive.org` links are not
   unwrapped.
3. **The source returns links; `Discovery` writes the log.** A source never
   writes (architecture rule 3). The MediaWiki sources put the page's outgoing
   links in the candidate as `:links`. `Discovery.run/2` pops them before
   `Documents.ingest/1` (rule 2: the only write path into the index), then
   logs the blocked ones in a transaction of its own, after the document is
   stored and after every external call (rule 5). Optional callback
   `Source.links/2` re-reads the links of a stored document for the backfill.
4. **`extlinks` in the request that already exists.** The page request adds
   `extlinks` to `prop` with `ellimit=max`: no new request for a page with 500
   links or fewer. A page with more answers with `elcontinue`, and the source
   sends up to 10 more requests for the links only (5,500 links in all). Only
   `elcontinue` is followed: Wikibooks' `tllimit=2` also makes most responses
   carry a `tlcontinue`, which is not ours. A failed continuation keeps the
   page and the links read so far: the text is what the fetch was for. A page
   that yields no candidate (disambiguation, compilation, missing) sends no
   continuation request. Every request still goes through `api_get/2`: it
   sends `maxlag` and holds a `:background` slot (ADR 0027).
5. **Only blocked links are stored.** Allowed links (a Wikipedia page that
   links to Wikibooks) and internal links are dropped. A row per internal
   link would cost about as much as a blocked-link row, 20 to 40 KB per page
   (a Wikipedia page has 120 to 260 internal links), for data nothing reads
   yet; and #89 wants the anchor text and the sentence of a link, which
   `prop=links` does not return, so the table #88 could create today is
   probably not the frontier #89 needs. Nothing is lost: the backfill below
   re-reads the links of every indexed page with one small request each, and
   #89 can run the same mechanism for internal links once it knows what to
   keep. `prop=links` is not requested at all: it would cost about 1.9 KB
   per page (gzip, *Bicycle tire*, 2026-11-10) and extra continuations.
6. **Table `blocked_links`.** Primary key `(document_id, url)` (`WITHOUT
   ROWID`, so the key is stored once), `host`, `first_seen_at`, `times_seen`;
   the page's row goes with the page (`ON DELETE CASCADE`). The view is one
   `GROUP BY host` scan; there is no other index until a measurement asks for
   one. About 165 bytes per row, so 2 to 20 KB per Wikipedia page (13 to 123
   external links on the pages probed), against roughly 200 KB for a page
   with its vectors. No pruning.
7. **`times_seen` counts index-time fetches.** A link counts once for every
   fetch of its page that saw it. The backfill is a first sighting only: a
   link already logged is left alone, so the backfill can run twice and does
   not change a count. A link that leaves a page stays in the log.
8. **The backfill.** `POST /api/blocked-links/backfill` and a button on
   `/blocked-links` enqueue one `Discovery.LinkBackfillWorker` job per indexed
   document of a configured source that implements `links/2` (a document of
   any other source is skipped). The request only
   enqueues (rule 6). The jobs are unique per document while incomplete, so a
   second `POST` adds nothing. They run in the `discovery` queue at priority
   3, behind search-time jobs, and are scheduled two a second: 120 requests a
   minute, under Wikimedia's 200 a minute, which the slots of ADR 0027 do not
   cover (they cap requests at once, not their rate). The route takes no
   input and has no rate limit of its own, like the rest of the API without
   authentication.

## Consequences

- The page request grows by about 3 KB (gzip, *Bicycle tire*: 10,535 to
  13,565 bytes with 123 links), and a page with more than 500 external links
  costs one extra request per 500, at most 10.
- Storage grows by about 165 bytes per logged link.
- A failed log write fails the discovery job and Oban retries it, which
  fetches the pages again; it is one short transaction, as likely to fail as
  an ingest write.
- A large backfill shares the `discovery` queue and the two background
  Wikimedia slots with search-time discovery; the priority and the schedule
  keep it behind searches.
- Other Wikimedia hosts show up as blocked. That is the list doing its job.
