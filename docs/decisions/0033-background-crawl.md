# 0033. The background crawl: score links before fetching them

- Status: Accepted
- Date: 2026-11-11

Related: issue [#89](https://github.com/williamge/knowseek/issues/89),
[0027](0027-wikimedia-concurrency-cap.md) (Wikimedia cap),
[0030](0030-sqlite-single-datastore.md) (SQLite, Oban Lite),
[0031](0031-activity-record.md) (the search log),
[0032](0032-crawl-allowlist-and-blocked-links.md) (the allowlist gate).

**What this decision covers.** The work was split in two pull requests: PR A
("preview", #100) reads the links of pages your searches showed, scores them,
keeps the good ones in a table and lists them on a Crawl page; PR B ("fetch
and gain") fetches the best candidate a minute while idle (mode `on`),
checks it again right before the fetch, and measures the gain. The sections
below describe the whole design.

## Context

Knowseek fetches pages only when a search finds weak coverage. #89 asks for
pages to arrive before they are needed: while the instance is idle, follow
the links of the pages you search for, but only the ones likely to answer
your own searches, so that the index grows where you look and not everywhere.
The allowlist gate of ADR 0032 already says which hosts may be fetched.

## The owner's answers

Scope (comment on #89, 2026-11-10): links one step out from pages that top
your searches, single-result pages first; candidates are Wikipedia and
Wikibooks links minus pages already indexed; scored on the title and
`prop=description` against the last 30 days of searches, plus novelty and a
gap bonus; only while idle (no search for 10 minutes and low CPU); at most
100 pages a day; gain is switched on; stored bytes per useful page is
reported.

| Question | Answer |
| --- | --- |
| Q1 What "already covered" means | **B**: count the stored pages near the candidate; novelty = 1 - pages near / 10 |
| Q2 Fill the 100 or stop at a bar | **B**: a bar on the score; 100 a day is only the ceiling |
| Q3 How far one search pulls | **C**: earned depth. Each time a page is in a search's top 3 it earns 5 link-fetches; as the single result, 15; ranks 4 to 10 earn 1; it expires with the 30 days |
| Q4 Which searches a link is compared with | **B**: the searches that showed the source page (the closest of them), flat over the 30 days |
| Q5 Seeing and steering | **B**: a read-only Crawl page and a preview mode (scores and lists, fetches nothing until switched on) |
| Q6 Pace | **B**: a trickle, one page a minute while idle |
| Q7 Gain | **C**: counted in pages (anywhere in the logged top 10) and in searches; stored bytes per useful page = bytes of all background pages / pages with gain |
| Q8 Link-graph signal | **B** (against the planner's recommendation): a bonus for a candidate linked from several of your source pages |
| R2-Q1 How rare sharing is | **C**: the shared-link bonus is scaled by how rare that sharing is among the source page's links |

Smaller decisions that stand: one request per source page for links and
descriptions; same-site links only; Wikipedia main namespace, Wikibooks main
and Cookbook; indexed pages, red links and disambiguation pages dropped; the
scoring text is "Title: description"; two stages (interest first, novelty
only above the interest floor); novelty looks at vectors only; sources come
only from logged results, never from a background page; low CPU is the
busy share since the last check under 60% (first version: the 1-minute load
average under half the cores, replaced, see "Idle, and `os_mon`"); every request goes through the
Wikimedia background slots (ADR 0027) and `Discovery.allowed?/1` (ADR 0032);
the provenance lives in the crawler's own tables, not in `documents`.

### Measurements behind Q1 and R2-Q1

Measured on the dev index with bge-m3 (2026-11-11):

- Q1: interest (the cosine of a link's "Title: description" with the search)
  and coverage (how many stored pages are near the link) correlate at 0.69.
  So coverage is not the same signal as interest, but close enough that a
  count of near pages is a fair "already covered" measure, and the two are
  multiplied, not added.
- R2-Q1: on the *Bowline* pages, 183 of 221 candidates were linked from all
  three source pages: most shared links are navigation boxes, so a flat bonus
  for sharing would reward the box. The rarity scaling gave 0.68 for "linked
  from all 3" on the sourdough pages and 0.03 on the bowline pages.
- A bar of 0.38 to 0.42 lets about 10% of a page's links pass. The values
  (0.40 and 0.40) come from two topics; the preview exists to tune them.

## Decision

### The new context and its boundary

`Knowseek.Crawl` (`backend/lib/knowseek/crawl.ex` and `crawl/`) owns two
tables and the logic. It reaches a source only through
`Knowseek.Discovery.link_candidates/1` and `Discovery.fetch_page/3`, the
search log through `Knowseek.Activity` (`result_pages/1`, `last_search_at/0`,
`hit_documents/1`), and the index through `Knowseek.Documents`
(`indexed_page_ids/2`, `summaries/1`, `stored_bytes/1`) and
`Knowseek.Search.count_near/2`. Its tables have foreign keys to `documents` in
the database only; no Ecto association crosses the context. `Source` gains
the optional callbacks `link_candidates/2` and `page/2`; `MediaWiki`,
`Wikipedia` and `Wikibooks` implement them. `Discovery` applies
`Discovery.allowed?/1` to every link it returns and to the URL of every page
it fetches, and ingests with origin `background`; a source never writes
(rule 3).

### One step out, earned depth

A **source page** is a document in the logged results of a search of the last
30 days, never a background page: the crawl does not follow links out of what
it fetched. A source page earns an **allowance** of link-fetches from the log:
5 each time it is in a search's top 3, 15 when it was the only result, 1 at
ranks 4 to 10. The allowance expires with the 30 days and is spent by fetches
(a `fetched` candidate of the source page). Source pages are read in this
order: pages that were a search's only result first, then the most shown,
then the most recently shown.

### The score

For a candidate `c` found on source page `S`:

```
interest = max over S's queries q of cosine(embed("Title: description"), embed(q))
near     = stored pages with a chunk at cosine >= min_similarity (0.5) to the candidate, at most 10
novelty  = 1 - near / 10
gap      = 0.10 if S was the single result of a search in the window, else 0
n        = read source pages of the same site that link to c (S included)
rarity   = ln(N / N_ge) / ln(N)     N = S's links, N_ge = S's links linked from at least n source pages; 0 when n = 1 or N < 2
shared   = 0.10 * min(n - 1, 2) / 2 * rarity
score    = interest * novelty + gap + shared
```

Only the vector side of search is used for novelty
(`Search.count_near/2`), so the number does not move with the full-text
ranking.

**Kept at read time, decided again at fetch time.** When a source page's
links are read, a candidate is stored when `interest >= 0.40` (the floor;
below it the index is not even asked) and `interest * novelty + gap + 0.10 >=
0.40` (it could pass with the largest shared bonus). At most 50 are kept per
source page. A candidate is fetched only when `score >= bar`, with `near` and
`shared` computed again just before the fetch ("Fetching"), so that "a topic
is full at about 10 pages" holds within one day even though the candidates
were scored earlier.

**Why the shared bonus is computed at ranking time.** It depends on the other
source pages. A source page read later changes the count for candidates
stored earlier, and a deleted source page changes it back. So the stored row
holds `shared` 0.0 and `shared_count` 1, and `Crawl` computes the bonus from
the link lists (`crawl_sources.link_ids`) whenever it ranks. That is also why
the link ids of every link are stored, not only those of the kept candidates.

### The scheduler, and why not Oban's cron

`Knowseek.Crawl.Scheduler` is a supervised timer (a `GenServer`) that ticks
once a minute. It only reads (`Crawl.due?/1`) and, if the crawl is due,
enqueues one `Knowseek.Crawl.Worker` job in the `crawl` queue (concurrency 1,
unique while one is incomplete). The job runs `Crawl.step/1`, which does one
action: read the links of the next source page that was not read yet, or was
read more than 7 days ago, and has allowance left. This is a further reading
of rule 6 (the timer is a small, state-free process like `Knowseek.Cache`; it
never does the work): `AGENTS.md` says so.

Oban's cron plugin would also work, but it inserts a job row every minute,
1,440 a day, for a check that is almost always "no". A search made while a step
runs waits behind at most one page's embedding batch; the next tick is no
longer idle.

### Idle, and `os_mon`

The instance is idle when no search was logged for `idle_seconds` (600, from
`CRAWL_IDLE_SECONDS`) and the CPU was busy less than `max_cpu_percent` (60)
since the previous check. The busy share comes from `:cpu_sup.util/0` (the
`os_mon` OTP application, started with `start_memsup: false, start_disksup:
false`, which would raise alarms): the percentage of CPU time spent busy since
the previous call. The scheduler checks once a minute, so it is the share over
the last minute; `cpu_sup` keeps the previous sample per calling process, so
only the scheduler asks. The first check after a start has no previous sample
and is **not idle**. A share that cannot be read also means **not idle**: the
crawl then never runs and the log says so once. No search at all counts as
quiet.

**Why not the load average.** The first version used the 1-minute load average
per core under 0.5. On macOS the load average counts threads that wait for the
disk or for swap, so it sat at 13 to 20 on 8 cores while the CPU was 46% busy
(`cpu_sup:util()` returned 46.0 while `avg1` was 13.08): the condition was
never true, and the crawl of the owner's stack never read a link. CPU
utilisation measures what the crawl should not compete for. The search log keeps the
first time of a search repeated within 120 seconds (ADR 0031), so idle can
start up to 2 minutes early.

### Modes

`CRAWL_MODE` (config `mode`): `off` (nothing runs), `preview` (reads and
scores, fetches nothing) and `on` (also fetches the best candidate a minute,
under 100 pages a day, a UTC day). **`preview` is the default**, so an
instance that is updated changes nothing it fetches; the owner reads the
Crawl page, tunes the bar in config and switches on with `CRAWL_MODE=on` and a
restart. There is no switch in the UI (a write endpoint without
authentication).

### Fetching

In mode `on`, a step that has no source page left to read fetches. Reads come
first, so that the link counts are as complete as they can be. The step takes
the ranked candidates (score at the bar or above, shared bonus included, best
first) and goes through the first `rechecks_per_step` (5) of them, stopping at
the first one that ends in a request:

1. A page that was indexed meanwhile (a search fetched it) is dropped.
2. The candidate's text is embedded again and its `near`, `novelty` and
   score are computed again with the shared bonus of the ranking. Under the
   bar, it is dropped without a request. This is what makes a topic fill up:
   each fetched page lowers the novelty of its neighbours, so a topic stops
   at about 10 pages. The owner approved the re-check.
3. `Discovery.fetch_page/3` checks the link and the page's own URL against the
   allowlist, makes the request (`Source.page/2`: the same request as a
   page fetched by a search), and ingests the page with origin `background`
   through the existing path, so its blocked links are logged too. The
   candidate becomes `fetched` with the scores that decided it and the
   stored bytes. A page with no text, or whose URL is off the allowlist, is
   `skipped`; a failed request sets `failed_at`, and the candidate waits 60
   minutes. A page a search stored meanwhile keeps its origin and the
   candidates for it are deleted.

A fetched page uses up one link-fetch of its source page's allowance. The
daily cap counts `fetched` rows since 00:00 UTC.

### Gain, and stored bytes

Gain is computed from the search log alone, with no new writes. The log
keeps, for each of a search's top 10 hits, whether the page was a background
page *at the time of the search*, so every such search was made after the
fetch. A search **counts** when at least one of its hits is a background
page and fewer than 3 (`min_strong_hits`, where coverage becomes
`sufficient`) are not: without the background page the search would not have
been well covered. `gain.pages` is the number of distinct background pages in
those searches (whole log), `gain.searches` the searches themselves in the
last 30 days, `gain.window_searches` all searches of those 30 days. No second
search is run. Stored bytes per useful page is the stored bytes of all
background pages (`crawl.stored_bytes`) divided by `gain.pages`; it is shown
on `/stats`. Stored bytes are an **estimate**
(`Documents.stored_bytes/1`): the body, the chunks' text and 4 bytes per
vector dimension per chunk, recorded when the page is fetched. The full-text
index and row overhead are not counted, so the figure is about 10% low.

### Storage

Two tables (migration `create_crawl_tables`), no query text in either, so the
tables hold nothing you typed:

- `crawl_sources`: one row per source page read (`document_id`, `site`,
  `link_ids`, `links`, `kept`, `read_at`). A rowid table: the JSON list of ids
  is too long for a `WITHOUT ROWID` row. About 2 KB per source page.
- `crawl_candidates`: one row per source page and linked page (`WITHOUT
  ROWID`), with the score parts, a `state` of `pending`, `fetched` or
  `skipped`, and, once fetched, the background page's `document_id`, its
  `stored_bytes` and `fetched_at`: the provenance of a background page. About
  250 bytes a row, at most 50 pending per source page. A `fetched` or
  `skipped` page is never a candidate again; fetching a page deletes the
  other pending rows of the same page.
- An expression index on `documents` (`source`, `json_extract(metadata,
  '$.pageid')`) lets `indexed_page_ids/2` answer without reading the bodies
  (about 40 bytes a document).

`DELETE /api/searches` also clears the link lists and the pending candidates.
Both tables go with their source document (`ON DELETE CASCADE`).

### The Crawl page

`GET /api/crawl` and `/crawl` in the web UI are read-only. They show the
mode, the bar, how many pages were fetched today of the 100, the next
candidates in the order they would be fetched (title, description, link, the
source page and the searches that showed it, and the score parts) and the
last 50 pages fetched (the same columns, plus when, and whether a search of
yours showed the page). In `preview` the "Next" list is what `on` would
fetch. There are no buttons.

## What was built

PR A (#100, preview): the migration; `Source.link_candidates/2` and its three
implementations; `Discovery.link_candidates/1`; `Search.count_near/2`;
`Activity.result_pages/1` and `last_search_at/0`;
`Documents.indexed_page_ids/2` and `summaries/1`; the context `Knowseek.Crawl`
(allowance, score, idle, frontier, scheduler, worker, `step/1` with the read
branch); `GET /api/crawl`; the Crawl page; the `crawl` key of `GET
/api/stats`; config and `CRAWL_MODE`, `CRAWL_IDLE_SECONDS`; the `crawl` queue;
`os_mon`.

PR B (fetch and gain): `Source.page/2` and its three implementations;
`Discovery.fetch_page/3`; the fetch branch of `Crawl.step/1` with the
re-check before a fetch (`rechecks_per_step`), the daily cap and mode `on`;
`Documents.stored_bytes/1`; `Activity.hit_documents/1` and gain in `GET
/api/stats`; the Gain section of `/stats`; the `fetched` list of `GET
/api/crawl` (and `document_id`, `fetched_at`, `stored_bytes`, `hit` on every
entry) and the "Fetched" table of the Crawl page.

## Not built

Not planned in #89 at all (non-goals): a link out of a background page and
any second step; "more like this"; book chapters; retries of thin searches
(#64); the sentence around a link, the page HTML, `prop=info`, `linkshere`
and page views of candidates; a size or cost term in the score; a disk or
network budget (#90); forgetting (#91); passage selection (#93); links between
Wikipedia and Wikibooks; buttons on the Crawl page (pause, skip, fetch now);
a mode switch in the UI; a marker for background pages in search results;
stored candidate vectors or stored query text. Nothing changes in
`SeekWorker`, `Lookup`, `Coverage`, `Search.search/2`, the allowlist or
`blocked_links`.

**Later rounds** (need the page HTML or more data): score on the sentence
around a link and tell a link in the text from one in a navigation box; stop
false friends (a title that shares a word with the search, such as *Sourdough
Sam*, passes any bar); more sites through the allowlist; the budgets (#90) and
forgetting (#91).

## Consequences

- The index grows by the crawl: at most 100 pages a day, one a minute while
  idle, each about 100 to 160 KB. The owner tunes `bar` and `interest_floor`
  in preview before switching on.
- A thin search log gives a thin crawl: a search answered empty and never
  repeated has no logged results, so it creates no source page.
- Links are scored on the title and the short description only. A link in a
  navigation box counts like a link in the text, and the shared bonus rarely
  fires because shared links are mostly navigation boxes.
- Each read costs about 9 KB and 5 seconds (one or two requests per source
  page, 500 links a response), through the background Wikimedia slots, and is
  counted in `network_usage` for the source.
- `os_mon` is a new OTP application in the release (no new dependency).
- A source page is read again after 7 days while it has allowance left: a page
  you keep landing on is not judged for weeks on the first day's index.
- `GET /api/crawl` has no authentication, like the rest of the API. It shows
  page titles and, for each source page, the queries that showed it (taken
  from the search log when the page is built; the crawl tables hold none).
