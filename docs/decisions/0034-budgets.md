# 0034. Budgets: 5 GB of disk and 200 MB of network a day

- Status: Accepted
- Date: 2026-11-11

Related: issue [#90](https://github.com/williamge/knowseek/issues/90),
[0030](0030-sqlite-single-datastore.md) (SQLite, the file and its
write-ahead log),
[0031](0031-activity-record.md) (the recorder, `network_usage`; this decision
amends what is counted),
[0032](0032-crawl-allowlist-and-blocked-links.md) (the link backfill),
[0033](0033-background-crawl.md) (the crawl; this decision corrects one
figure of it).

## Context

Knowseek stores everything it fetches and the crawl of ADR 0033 adds pages
while you are away. #90 fixes two ceilings: **5 GB of disk in total** and
**200 MB of network a day**. Storage comes first and network a close second.
Forgetting is #91 and pinning #92; search-time discovery stays. Before this
decision nothing stopped any fetch, and the byte counter covered only the
Wikipedia and Wikibooks requests of discovery jobs, bodies only.

## The owner's answers

Questions of design round 1, answered 2026-11-11:

| Question | Answer |
| --- | --- |
| Q1 What counts as disk | **A**: everything the database takes: the file's pages in use plus the write-ahead log |
| Q2 Which downloads count | **B**: everything Knowseek downloads, including Wikidata, the card sources and response headers; one row per source on `/stats` |
| Q3 Who is held back at a limit | **B**: two steps. Background work stops at 90%, typed-search fetching at 100%. Search still answers from the index and says it fetched nothing new |
| Q4 The 100 pages a day | **A**: the cap stays next to both budgets; whichever comes first |
| Q5 Search speed | **A**: #90 only shows the passage count, with a note from 100,000. The follow-up (smaller vectors, faster scan) is named, not created |
| Q6 What you see | **B**: bars on `/stats`, a reason on the Crawl page, and a notice on the search page only when a fetch was refused. Bars turn to a warning colour at 90% |
| Q7 Where the setting lives | **A** (against the planner's recommendation): config only. Two environment variables and a restart, like `CRAWL_MODE`. The UI shows the values. No settings table, no write route |
| Q8 Free disk space | **B**: background work also stops under 1 GB of free disk; the free space is shown next to the disk bar |

Decided by the planner and not vetoed: the budget day is the UTC day;
decimal units (5 GB is 5,000,000,000 bytes); a check before each action and
no reservation; free pages in the file are not "used"; the write-ahead log
counts; response headers count from now on; crawl link reads are background
work; the link backfill is held back like the crawl; no CPU budget; the
local Ollama is not network; no log is pruned; no "delete the oldest"
stopgap; one budget state read by every caller; `stored_bytes` is not used
for the budget; the budgets apply in every crawl mode.

The owner decided one point of the plan otherwise: **when the free disk space
cannot be read, background work is held back** (the plan had treated
unknown as not low). A crawl that cannot see its safety line does not run.

### Measurements

Taken on 2026-11-11 from a copy of the dev database (the live file was never
opened), 20 GET requests to en.wikipedia.org (2 link reads, 18 page requests
as the app sends them) and a synthetic index built from those 18 pages
(1,800 pages, 16,200 passages, 67,200 blocked links, 123.9 MB; sqlite-vec
0.1.9, random vectors). No Ollama calls.

What a page costs on disk (synthetic index, 18 real pages stored 100 times):

| Part | Per page | Per passage | Share |
| --- | --- | --- | --- |
| Vectors (float32, 1,024 numbers) | 37.3 KB | 4,147 B | 54.2% |
| Passage text (`chunks`) | 10.5 KB | 1,166 B | 15.2% |
| Page text and row (`documents`) | 9.1 KB | 1,012 B | 13.2% |
| Blocked-link log (37 links a page, 187 B each) | 7.0 KB | 774 B | 10.1% |
| Full-text index | 3.5 KB | 389 B | 5.1% |
| All other indexes and bookkeeping | 1.4 KB | 159 B | 2.1% |
| **Total** | **68.8 KB** | **7,647 B** | |

- The sample page has 8.0 KB of text and 9 passages on average. **5 GB holds
  about 72,600 such pages, or 654,000 passages.** The text is stored twice
  (page and passages): 28% together.
- sqlite-vec reserves room for 1,024 vectors at a time (4.2 MB), so the file
  grows in 4.2 MB steps and a small index looks bigger than it is.
- The `stored_bytes` estimate of ADR 0033 gives 52.9 KB for the same page:
  **23% low**, not the 10% ADR 0033 says. The blocked-link log is most of the
  difference.
- Caveat: the pages were picked at random from two pages' links, not by the
  crawl's score. A crawled page may cost twice as much (16 to 27 passages
  were seen on pages near a search).

Deleting does not give vector space back (16,200 passages, 123.9 MB):

| Step | File | Free pages inside | Vector table |
| --- | --- | --- | --- |
| Full | 123.9 MB | 0 | 67.2 MB |
| Half the pages deleted (at random) | 123.9 MB | 21.9 MB | 67.2 MB |
| The same number of pages added again | **159.5 MB** | 0 | 100.8 MB |
| Those deleted again | 159.5 MB | 55.9 MB | 67.2 MB |
| `VACUUM` (2.0 s) | 99.6 MB | 0 | **67.2 MB** for 8,266 vectors (33.9 MB needed) |

Text, indexes and log rows that are deleted become free pages that the next
insert reuses. **A deleted vector's slot is never reused** (sqlite-vec 0.1.9),
a block of 1,024 is given back only when all of it is gone, and `VACUUM` does
not close the holes. The file never shrinks by itself (`auto_vacuum` is off).
`VACUUM` needs about as much free disk as the database is big and left a
100 MB write-ahead log; the log also reached 59 MB during one delete.

The cost of a reading:

| Reading | Cost |
| --- | --- |
| File pages in use (`page_count`, `freelist_count`, `page_size`) | 6 microseconds |
| Size of the write-ahead log (one file stat) | 4 microseconds |
| Number of passages (`count(*)`) | 0.2 ms at 8,000 rows |
| Free disk space (`:disksup.get_disk_info/1`, with `disksup` running) | 16 ms |
| Breakdown by part (`dbstat`, reads every page) | 0.41 s for 124 MB: about 3 s per GB `[INFERENCE: linear, warm cache]` |

Network:

| What | Result |
| --- | --- |
| `network_usage` in the dev database | One row: wikipedia, 61,807 bytes for one search (1 search request and 3 page requests, 3 pages stored): 20.6 KB per stored page |
| One page request, 18 linked pages (body as counted before this decision, gzip) | 0.9 to 15.8 KB, median 2.9 KB, **mean 4.75 KB** |
| Response headers of the same requests (not counted before) | **1.8 KB each**: 38% on top of the mean page |
| One link read (`generator=links`) | 5.1 KB (*Bowline*, 213 links) and 6.8 KB (*Sourdough*, 201 links), plus 1.8 KB of headers |
| Wikidata lookups and cards | **Not measured** (outside what the design round could call). Each typed query asks Wikidata for up to 20 entities with all their claims and sitelinks `[INFERENCE]`: tens to hundreds of KB per new query. The first day of data measures it |

What the numbers add up to:

| | Network a day | Disk a day | 5 GB reached in |
| --- | --- | --- | --- |
| Crawl at the cap (100 pages, about 20 link reads) | 0.6 MB counted before, 0.8 MB with headers: **0.3 to 0.4%** of 200 MB | 6.9 MB | about 2 years (1 year if crawled pages are twice the sample's size) |
| Crawl with no page cap (one a minute, all day: 1,440 pages) | 9.5 MB with headers: 5% | 99 MB | 50 days |
| 200 MB spent on page fetches | 200 MB | 42,000 pages, **2.9 GB** | under 2 days |
| 10 searches a day on topics the index lacks | 0.6 MB | about 3 MB | not by itself |

**One downloaded byte becomes about 14 stored bytes** (4.75 KB in, 68.8 KB on
disk). Disk is the budget that runs out; the crawl as built cannot reach the
network budget. Search slows down long before the disk fills: it compares the
query with every stored vector, 105 to 240 ms at 100,000 passages (ADR 0030),
which is 0.77 GB, 15% of the budget and about 4 months at 100 pages a day;
at 654,000 passages (5 GB) about 0.7 to 1.6 s `[INFERENCE: linear]`.

## Decision

### What "disk used" is

```
disk used = (page_count - freelist_count) * page_size + size of the -wal file
```

Everything in the file counts: text, vectors, the full-text index, the logs,
job rows and the crawl tables. Free pages inside the file do not count, since
the next insert reuses them. The holes left by deleted vectors do count,
since nothing reuses them (they are pages in use). The write-ahead log counts
(one file stat); the 32 KB `-shm` file does not. The figure can be a little
below the file's size on disk. Two cheap readings (microseconds each), so it
is checked before every action.

### What "network used" is

```
network used = sum of network_usage.bytes for today's UTC day, all sources
```

Everything Knowseek downloads is counted, in `network_usage` per UTC day and
source: `wikipedia` and `wikibooks` (searches, the crawl's link reads and
fetches, the link backfill), and, new, `wikidata`, `edgar`, `open_meteo`,
`balldontlie` and `voyage` (a hosted embedding service; only its responses).
The size of a response is the HTTP/1.1 text size of its headers (each line
`name: value` and its line break) plus the body as received, still
compressed (`Knowseek.Download.size/1`). Not counted: request bytes and TLS
(about 0.3 KB a request), the local Ollama (it is not network) and the text a
hosted embedding service receives. Over HTTP/2 the real bytes are fewer, so
the counter errs high by a little. Days already recorded stay as they were
(bodies only, discovery sources only). This amends ADR 0031.

`Knowseek.Download.measure/2` is a Req response step that runs before `retry`
and `decompress_body`, so it sees every attempt and the compressed body. A
discovery source reports through the `:on_bytes` function `Discovery` gives
it, as before: a source never writes (rule 3). The other clients (Wikidata,
the three card sources, Voyage) call `Download.count/2`, which sends the
bytes to the configured sink, `Knowseek.Activity.count_bytes/2`: one message
to `Knowseek.Activity.Recorder`, no write in the request path.

### The rules

```
level(used, limit) = :full when used >= limit; :near when used >= share * limit; else :ok
free disk low      = the check is on (floor above 0) and the free bytes of the
                     database's volume are below the floor (1 GB) or cannot be read

background hold = :disk when the disk level is :near or :full
                  else :free_disk when free disk is low
                  else :network when the network level is :near or :full
                  else nil
search hold     = :disk when the disk level is :full
                  else :network when the network level is :full
                  else nil
```

`share` is `background_share`, 0.9. A limit of 0 makes the level `:full` at
once: `DISK_BUDGET_MB=0` or `NETWORK_BUDGET_MB=0` stops all fetching. The
search hold makes no free-disk reading, so it is safe in the request path.

| Who | Asks | When held |
| --- | --- | --- |
| `Crawl.due?/1` (the scheduler, once a minute) | background hold | No job is enqueued |
| `Crawl.step/1` (the job; link reads and fetches, in every mode) | background hold | Does nothing |
| `LinkBackfillWorker` | background hold | `{:snooze, 86_400}` |
| `Discovery.request/1` (a typed search) | search hold | `{:error, {:budget, reason}}`; the search response says `refused` |
| `SeekWorker` (when the job runs) | search hold | `{:cancel, {:budget, reason}}` |
| Wikidata, cards, embeddings, `POST /api/documents` | nobody | Never held |

The state is computed in one place, `Knowseek.Activity.budget/1`
(`Activity.hold/2` for the callers); the pure rules are in
`Knowseek.Activity.Budget`. `Crawl`, `Discovery` and `Lookup` already depend
on `Activity`, so no new dependency between contexts appears.

### Why the checks sit in the callers

Not in `Documents.ingest/1` and not on `POST /api/documents`: rule 2 keeps
one write path into the index, and a page you add by hand is never refused
(at most 1 MB, and you asked for it). `Discovery.run/2`, `fetch_links/1`,
`link_candidates/1` and `fetch_page/3` do not check either, so a test or a
job that calls them directly is not affected. The `SeekWorker` checks again
when it runs, so a job enqueued just before the limit, or a flood of them,
does not run past it.

Cards and Wikidata lookups are counted but never refused, also when the
network budget is used up: they are bounded by their caches (ADR 0023), and a
weather card that stops at 200 MB helps nobody. So "nothing passes 200 MB"
has this one exception.

### The recorder also writes byte counts

`Activity.count_bytes/2` casts `{:bytes, source, bytes}` to
`Activity.Recorder`, which calls `record_bytes/3`. This is the same exception
to rule 6 as for the search log (ADR 0031), with the same cost: best effort.
A count sent just before a stop is lost, and one is dropped when the write
lock stays busy for 5 seconds, with a warning. The counter can only be low,
never high. A count of 0 sends nothing.

### Free disk space and `disksup`

The free space of the volume that holds the database comes from `:disksup`
(`os_mon`), switched on with `disk_almost_full_threshold: 1.0` (alarm above
100%: never), so it raises no alarms. `Activity.budget/1` reads
`:disksup.get_disk_info/1` for the database's directory: 16 ms a reading, and
it needs the `disksup` process (without it the answer is `[{path, 0, 0, 0}]`).
Only background work reads it, once per check.

**Unreadable free space holds background work back** (the owner's decision):
`free_disk.low` is true when the check is on and the reading is below the
floor or `nil`, and `hold(:background)` is then `:free_disk`. `/stats` shows
"unknown" for `bytes: null`. A floor of 0 turns the check off: no reading is
made, `bytes` is `nil` and `low` is `false`. The first unreadable reading
after a start is logged once. Typed searches never read free disk.

### The link backfill waits 24 hours

When held back, `LinkBackfillWorker` returns `{:snooze, 86_400}`, a fixed
wait and not "until midnight": every waiting job moves by the same 24 hours,
so the pace of two requests a second set by `backfill_links/0` (ADR 0032)
holds. The Blocked links page does not say that it waits.

### Configuration

`config :knowseek, Knowseek.Activity`: `disk_budget_bytes` (5,000,000,000),
`network_budget_bytes` (200,000,000), `background_share` (0.9),
`min_free_disk_bytes` (1,000,000,000). `DISK_BUDGET_MB` and
`NETWORK_BUDGET_MB` (whole megabytes, 1 MB is 1,000,000 bytes, 0 allowed) set
the first two; a value that is not a whole number raises at start.
`config :knowseek, Knowseek.Download, sink: {Knowseek.Activity,
:count_bytes}`. Tests turn the free-disk check off and use no sink unless
they ask for one.

### What you see

`GET /api/stats` loses `disk_bytes` (the file's size) and gains `budget`
(`disk`, `network`, each with `used`, `limit` and `state` of `ok`, `near` or
`full`; `free_disk` with `bytes`, `floor`, `low`; `background_share`) and
`passages`. `POST /api/search` has a fourth `discovery` form,
`{"status": "refused", "reason": "disk" | "network"}`, with status 200 and
the hits as always. `GET /api/crawl` gains `paused`: `null`, `"disk"`,
`"network"` or `"free_disk"`. The Stats page shows two bars, the free space
and the passage count (with a note from 100,000 passages); the Crawl page
says why it is paused; the search page says only when a fetch was refused.

## Not built

- Settings in the UI (Q7): needs authentication (#86). A web page you visit
  can write to `127.0.0.1:4000`.
- A breakdown of the disk by part: an exact one reads the whole file (about
  3 s per GB).
- A passage ceiling or any change of the vector format (Q5). Follow-up, not
  created here: "Smaller vectors and a faster vector scan". Int8 vectors
  would make a page cost about 41 KB instead of 69 KB; the speed needs the
  next sqlite-vec release or an approximate index.
- Forgetting (#91), pinning (#92), pruning of any log, `VACUUM`, a "delete
  the oldest" stopgap.
- A CPU or embedding-time budget: the idle rule and the pace of ADR 0033
  stand.
- Refusing cards or Wikidata lookups, a count of request bytes or TLS, a
  notice on the Blocked links page.

## Consequences

- A budget can be passed by one action in flight: one page (about 0.3 MB
  stored), one 4.2 MB step of the vector table, or the discovery jobs already
  running (at most 5). There is no reservation.
- Before #91, a full disk budget means stop: nothing frees vector space (see
  the measurements), so the only answer is to raise `DISK_BUDGET_MB`. #91
  needs a rebuild of the vector table or a newer sqlite-vec.
- Search slows long before 5 GB (100,000 passages is about 0.8 GB). `/stats`
  shows the count and the note; the follow-up is named above.
- Counts are best effort and can only be low. Wikidata's size is unknown
  until the first day of data; if one lookup is hundreds of KB, typed
  searches become the main network consumer.
- Until #111 no client asked for compressed responses, so the counter
  recorded full sizes. Every remote client now sends `accept-encoding` with
  `gzip` (`compressed: true`), and the counter records the compressed sizes
  (on a preview, one weather card and one search: Wikidata 1.5 MB to 0.28 MB).
  What is counted (headers plus the body as received) did not change.
- The recorder gets more messages: two per Wikidata lookup and one per card
  refresh. It is one process; a long ingest delays the counts, never a search.
- `disksup` runs `df` every 30 minutes and on each background check. The
  release image needs `df` (coreutils) `[INFERENCE: present in the Debian
  base, not run]`; if the reading fails, background work is held back and
  `/stats` says "unknown". With `min_free_disk_bytes: 0` the check is off.
- Cancelled seek jobs show up as `cancelled` in `oban_jobs` for 7 days while
  a budget is used up.
- The day is the UTC day: for the owner the network budget starts again in
  the afternoon or evening, local time.
- `Documents.stored_bytes/1` of ADR 0033 is about 23% low, not 10%; it stays
  the figure for "bytes per useful page" and is not used for the budget.
