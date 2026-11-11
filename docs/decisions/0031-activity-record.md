# 0031. A local record of searches, page origins and downloads

- Status: Accepted
- Date: 2026-11-11

Related: issue [#96](https://github.com/williamge/knowseek/issues/96) (this
change), [#88](https://github.com/williamge/knowseek/issues/88) (links, the
allowlist and the blocked-link log; ADR 0032), and the crawling work that
follows (#89, #90). Builds on [ADR 0030](0030-sqlite-single-datastore.md).

## Context

Before Knowseek crawls in the background (#89), the owner needs numbers to
judge whether it pays off: how many searches there are, how well the index
covers them, where each page came from, what it costs in bytes, and how often
a crawled page shows up in a result. Nothing recorded any of that.

Three of the repository's rules are in the way:

- **Rule 6** (slow or external work runs in Oban jobs; the request path may
  only enqueue). A search is the thing to log, and the log row is a write.
  SQLite has one writer and every transaction starts IMMEDIATE (ADR 0030), so
  a write in the request waits behind an ingest. `Oban.insert/1` is itself a
  write: it waits for the same lock, and a job costs three more writes and a
  seven-day copy of the query and hits in `oban_jobs`. Nothing about a log row
  is external or worth a retry.
- **Rule 3** (a source never writes). The bytes a source downloads are known
  only inside the source, in every request it makes, including those that end
  in no candidate (the search request, skipped pages, failed fetches).
- **Rule 1** (context boundaries). Hit share needs "which top results were
  background pages", which lives in `documents`.

## Decision

### The search log, and a second exception to rule 6

`Knowseek.Lookup.run/2` hands each successful search to
`Knowseek.Activity.record_search/4`, which sends one message
(`GenServer.cast`) to `Knowseek.Activity.Recorder` and returns. The recorder is
a supervised in-process `GenServer` with no state, one per node, started
after `Knowseek.Repo`. It writes the row (`Activity.SearchLog.store/1`) outside
the request, so the request never takes the write lock for the log.

This is a second named in-process exception to rule 6, next to
`Knowseek.Cache`. `AGENTS.md` says so. The cost: **the log is best effort.** A
search handed over just before the node stops is lost, and a row is dropped
(with a warning in the log) when the write fails, for example when the lock
stays busy past the 5 s `busy_timeout`. The recorder rescues any error so that
it cannot crash-loop and stop the application's supervisor. "Kept forever"
means "never pruned". Searches never wait for the log. `clear_searches/0`
goes through the recorder, so the delete runs after the searches the recorder
still holds; it waits for the lock, as an explicit user action may.

`Search.search/2` logs nothing; only `Lookup` does. A failed search logs
nothing.

### What one search is

The web UI searches the same query again by itself while it waits for
discovery (every 3 s for up to 90 s, when new documents arrived). Logged
naively, one typed search would be two or three rows, first `none`, then
`sufficient`. So a search with the same normalized query as a logged search
less than 120 seconds old (`inserted_at` of the logged row) is the same
search: the row keeps its time and its first coverage (how well the index
covered what you asked, when you asked) and takes the newest top results
(what you ended up seeing). The recorder looks for the repeat among the
newest 20 rows by rowid.

### Stored per search

`searches` (`query` normalized and cut to 500 characters, `coverage`,
`inserted_at`) and `search_hits` (the top 10, keyed by `{search_id, rank}`,
`WITHOUT ROWID`): `document_id`, `positions` and `background`.

- **Positions, not chunk ids.** A chunk id is 36 bytes of text and four of
  them per hit would be 1.4 KB per search. `positions` are `chunks.position`
  of the best chunk, then of the passages shown; `(document_id, position)` is
  unique. Both go stale when a body changes and is re-chunked; positions still
  point at roughly the same place.
- **No foreign key on `document_id`.** The history survives a deleted
  document, and `Activity` never joins `documents` (rule 1).
- **`background` is copied onto the hit.** `Knowseek.Search.Hit` now carries
  `position` and `origin` (read in the query `load_hits/1` already runs, the
  read join `Search` may make), and the recorder stores
  `origin == "background"` on the hit. The origin is write-once, so the copy
  cannot go stale.
- **Size:** about 60 bytes per search plus 55 per hit, about 600 bytes with 10
  results: 22 MB a year at 100 searches a day. The 36-byte document id is most
  of it. Storing UUIDs as blobs would save a third and break ADR 0030's "UUIDs
  are TEXT", so it is not done.

The log holds what the user typed, in plain text, until cleared
(`DELETE /api/searches`; the stats page says so next to the button).

### Origin of a page

`documents.origin` is `search`, `background` or `manual` (CHECK constraint,
default `manual`), and `documents.origin_query` is the normalized query (at
most 500 characters) for `search`, else NULL. Both are **write-once**:
`Document.ingest_changeset/2` casts them only for a new document, the
`on_conflict` of a concurrent first ingest keeps them, and `Documents.ingest/1`
ignores them for a document that exists (by URL, alias or content). The origin
says why a page *first* entered the index; a background page stays
`background` when a later search fetches it again, which hit share depends on.
`Discovery` sets `search` and the query; the manual endpoint forces `manual`
(a caller cannot choose); nothing sets `background` until #89. The migration
backfills the documents that are already indexed from sources other than
`manual` and `seed` as `search` with no query (the Oban jobs that had the
query are pruned after 7 days), and indexes `origin` so that counting pages by
origin does not read the bodies.

### The byte counter, and rule 3

Sources get a new option: `discover(query, opts)` may find `opts[:on_bytes]`, a
function of one argument that the source calls with the body size of every
HTTP response it receives. `Knowseek.Discovery` creates it around each source
call: it only adds to an in-memory `:counters` reference. After the source
returned, `Discovery` writes the total with `Knowseek.Activity.record_bytes/2`
(one upsert per source and run, after the external calls: rules 3 and 5). The
source writes nothing. A failed source's bytes are recorded too.

Why a callback and not a candidate field: bytes are also spent on the
`list=search` request, on pages that are skipped and on failed fetches, none of
which has a candidate, and an `{:error, reason}` carries nothing. Telemetry
was rejected: a handler runs in the process of the HTTP code, so a handler
that writes would be a write from inside the source.

`MediaWiki` implements it as a Req response step that runs before `retry` and
`decompress_body`: it counts the body as received (compressed), once per
attempt, headers not counted. `network_usage` holds bytes per UTC day per
source.

**Counted:** the discovery sources (Wikipedia, Wikibooks). **Not counted:**
card providers, Wikidata lookups and a hosted embedding API.

### Hit share

Hit share is "of the background pages, how many showed up in the top results
of a logged search": `background_pages` (documents with origin `background`)
and `hit_pages` (distinct documents of hits with `background` true). The UI
computes the percentage; with no background pages there is none. It reads "0
of 0" until #89 writes background pages.

### The numbers

`GET /api/stats` (`Knowseek.Activity.stats/1`): searches per UTC day by coverage
for the last 30 days (and the total ever), pages by origin, the size of the
database file (`page_count * page_size`; the WAL file is not counted), network
bytes per day and source for the last 30 days, and hit share. The web UI shows
it at `/stats`, with links at the bottom of every page.

## Consequences

- The owner can read the effect of crawling from local numbers, and clear the
  search history.
- A second process (the recorder) writes to the database. It is a single
  global process, so every database test drains it in `on_exit`
  (`DataCase`).
- The log can miss a search on a crash or a busy lock. That is accepted; the
  alternative, an Oban job, makes every search wait for the write lock.
- About 600 bytes of storage per logged search.
- Not built, left to #89: a "gain" figure and a second coverage check per
  search, the `background` writer and the columns for "the page and link it
  came from". #88 adds the link backfill; its downloaded bytes are counted
  through the same `:on_bytes` option.
