# 0035. Record the embedding model, and re-embed by itself after a change

- Status: Accepted
- Date: 2026-11-13

Related: issues [#84](https://github.com/williamge/knowseek/issues/84) and
[#53](https://github.com/williamge/knowseek/issues/53) (both closed by the
first PR of #84), [#83](https://github.com/williamge/knowseek/issues/83) (re-cutting pages from stored text, the second PR),
[#90](https://github.com/williamge/knowseek/issues/90) (budgets),
[0004](0004-embeddings.md), [0007](0007-embedding-providers.md),
[0016](0016-ollama-default-embeddings.md) (Ollama is the default),
[0030](0030-sqlite-single-datastore.md) (SQLite, sqlite-vec, Oban Lite),
[0033](0033-background-crawl.md) (the crawl).

## Context

Vectors of two models cannot be compared. Until now nothing said which model
made a stored vector: after a switch of adapter or model the owner had to run
`make db-reset`, and `Documents.ingest/1` skips a page whose body is
unchanged, so re-ingesting did not help (#53). The crawl made this worse:
its novelty count (ADR 0033) compares a candidate with stored vectors, and
with a mix of models the count means nothing. #84 asks that the model be
recorded and that a change be repaired without a reset.

## The owner's answers

Round 1 (2026-11-12):

| Question | Answer |
| --- | --- |
| Q1 The configured model differs from the stored vectors | **A**: start, and re-embed in the background by itself. Search works throughout; a page not yet redone is found by keyword only |
| Q2 Stored text of a trimmed page (#93, #91) | **B**: the full text is kept only while a page is kept whole; a trimmed page's passages are its stored text; the hash of the full text is kept. (Shapes this PR in one way: a model switch re-embeds passages, it never re-cuts) |
| Q3 One PR or two | **B**: this PR is #84 with #53 folded in; #83 later |
| Q4 int8 | **C**: not here. The quantization is recorded as `float32`; int8 is the very next PR (#107), before the crawl fetches for real |
| Q5 What you see | **C**: `/stats` shows the model and the progress; the search page shows one line while a re-embed runs |
| Q6 A new digest under the same model name | **A**: it is a new model |

Approval of the plan (2026-11-13): yes to both open questions. `make reindex`
("embed everything again although the model did not change") moves to the #83
PR, because it has no use until that PR can also re-cut. The migration deletes
the stored vectors, and every page is re-embedded at the first start.

## Decision

**What a model is.** One row of `embedding_models` per model that made
vectors stored here: `name` (provider and model: `ollama/bge-m3:latest`,
`hashing/1`, `voyage/voyage-3.5`), `digest` (Ollama's digest from
`GET /api/tags`, `""` for a provider that has none), `dimensions` and
`quantization` (`float32`; `Knowseek.Documents.Vector.quantization/0`). Those
four are the identity (a unique index), so a new digest under the same name
is a new model (Q6). `inserted_at` says when the model was first used here;
the crawl reads it.

**The record.** `documents.embedding_model_id` says which model made the
page's vectors (NULL: none known; foreign key, `ON DELETE SET NULL`, indexed).
The same id is mirrored on every vector as the *partition key* of
`chunk_vectors` (`embedding_model_id integer partition key`). A search then
compares only vectors of the current model. A partition key and not a
metadata column, because sqlite-vec filters a partition key before the scan
(a metadata column scans every row). A vec0 table cannot be altered (no new
column) and a renamed one is broken (sqlite-vec 0.1.9), so the migration
drops it and creates it again. A virtual table cannot hold a foreign key, so
no key points from it to `embedding_models`.

**The migration deletes the stored vectors.** They have no known model.
Carrying them as "unknown" would hide them from search through the model
filter until a re-embed, and the re-embed redoes every page anyway, so the
rows would be deleted a moment later. The space of the old vectors (4.1 KB per
passage) is reused by the new ones. The first start re-embeds every page:
search finds pages by keyword only meanwhile, and the crawl reads its source
pages again. Rolling the migration back copies the vectors of whatever model
into the old single table; it does not bring the deleted ones back.

**Which model the app uses.** `Knowseek.Embeddings.model/0` asks the
configured adapter (`model/0` is a callback of every adapter) and remembers
the answer in `:persistent_term` for as long as the adapter stays the same;
`refresh_model/0` asks again. `Embeddings` stays free of the database.
Ollama reads the digest from `GET /api/tags` (verified on Ollama 0.40.13:
`{"models": [{"name": "bge-m3:latest", "digest": "7907...", ...}]}`).
`Hashing` reports `hashing/<version>` (config key `version`, default 1, so a
test can stand in a model change). `Voyage` reports `voyage/<model>`.

**Re-embedding in place.** A page is *stale* when its `embedding_model_id`
is not the current model's, or is NULL. In SQL: `embedding_model_id IS NOT ?`,
and when the current model has no row yet the parameter is bound as `-1`, not
NULL: `NULL IS NOT NULL` is false, and the pages that the migration left
with NULL would never count as stale. `Knowseek.Documents.Reembed` takes the
stale pages in storage order (the page whose first passage is oldest first),
embeds a page's passages outside any transaction in requests of 4, then in one
transaction deletes the page's vector rows and inserts them again under the
same `rowid` with the new id (a partition key cannot be updated), and stamps
the page with `update_all` (so `updated_at` does not move). The delete is row
by row: `DELETE ... WHERE rowid IN (...)` scans the table (16 ms for 5 rows at
50,000 rows; a point lookup is 1.5 ms). If a concurrent ingest replaced the
page's passages between the read and the write, nothing is written (the ingest
stamped the page itself). `chunks`, `chunks_fts`, chunk ids, positions, `body`
and `content_hash` are never touched: a model switch re-embeds passages, it
never re-cuts (Q2). `Documents.ingest/1` still skips an unchanged body; the
background job, not re-ingest, repairs stale vectors. When no page is stale,
the model rows that no page uses are deleted, except the current one.

**Who starts it.** `Knowseek.Documents.ModelWatch` is a supervised timer that
checks right after the start and then once a minute: it asks the provider
which model it serves (one `GET /api/tags` to the local Ollama, about 2 ms,
and one indexed query) and, when pages are stale, enqueues
`Knowseek.Documents.ReembedWorker`. It only reads and enqueues, with
`Crawl.Scheduler` (ADR 0033) as its precedent; rule 6 of `AGENTS.md` lists it
next to the other timers. An `ollama pull` while the app runs is noticed
within a minute. The job runs in the new queue `index` (one slot, so one job at
a time): 20 pages per job, requests of 4 passages (a search embeds its query
through the same server and waits behind one request; 2.7 s behind 32
passages, 0.9 s behind 12, 0.26 s behind 4), and, while pages are left,
enqueues its successor. It is unique over `available`, `scheduled` and
`retryable` jobs but not `executing`, so the running job can enqueue the next
one and a job orphaned by a crash blocks nothing. A failed embedding fails the
job (5 attempts); the watch enqueues a new one when they are used up. The log
says when the re-embed starts (with the model, its digest and the counts),
when it finishes, and when the provider cannot be asked.

**Search during a re-embed.** `Search.search/2` and `Search.count_near/2`
filter the vector query by the current model's id, so only redone pages have a
vector hit; a page not yet redone is found by keyword only (Q1). A search
waits at most one request of 4 passages (about 0.25 s) longer. With no vector
of the model yet, the vector list is empty. `/api/search` returns
`reembedding` (`null`, or `{done, total}` in passages) and the search page
shows one line; `/api/stats` returns `index` (the model, `passages`,
`current_passages`, `eta_seconds`) and `/stats` shows it (Q5). The estimate
uses a fixed 75 ms per passage (measured 71.7 to 75 on the owner's M1), not a
measured rate, and is labelled "about".

**The crawl pauses.** `Crawl.due?/1` is false while a page is stale: novelty
counts stored pages near a candidate, and during a re-embed it would see only
the pages already redone, so everything would look new. Candidates scored
before the current model's row was created (`embedding_models.inserted_at`)
are not ranked, and a source page read before it is read again (its next read
replaces the pending rows with scores of the current model). No row is
deleted; fetched and skipped rows stay as provenance. The cost is one link
request per source page with allowance (about 9 KB each, ADR 0033), and it also
happens once at the first start after this change, because every old vector
counts as unknown. The crawl's own embeddings (the queries, the link texts)
always use the configured adapter, so they are of the current model by
construction.

**Not subject to #90's budget.** The re-embed downloads nothing (the local
Ollama is not network, as #90 decided) and its disk peak is one 4 MB block
(+1% measured: the pages are redone in storage order, so a freed block is
reused; the other order would peak at +98%). Blocking it on a full disk would
leave pages unfindable by meaning with nothing that could fix them. It never
calls the budget check.

## Measurements (round 1, SQLite 3.54.1, sqlite-vec 0.1.9)

- A partition key adds 0 bytes with one model and 4 MB per further model, and
  the filtered KNN takes the same time: 136 ms against 140 to 147 ms at
  100,000 vectors. A filtered KNN fills `k` from that model's rows only, and
  the app's `WITH knn AS MATERIALIZED` shape works with the filter.
- `UPDATE` of the partition key is refused; delete and insert under the same
  rowid works.
- `up` and `down` as raw SQL in one transaction, with the `chunks_after_delete`
  trigger in place: after `up` a chunk delete and a cascading document delete
  still remove the vector rows; after `down` KNN works on the copied rows.
- The stale-page query reads indexes only: 24 ms for 10,000 pages; `stale?` is
  0.03 ms. The two passage counts cost 0.4 ms and 3.6 ms at 50,000 passages
  (counting in `chunk_vectors` would scan the vectors: 210 ms at 100,000).
- bge-m3 on the owner's M1: 71.7 ms per passage.

The `ADD COLUMN ... REFERENCES` of the migration DSL was emitted as written by
ecto_sqlite3, so no fallback to a column without a foreign key was needed.

## Consequences

- Switching adapters or models needs no reset: the next start (or, with the
  app running, the next minute) re-embeds the stored passages in the
  background. A model change is noticed up to a minute late; pages ingested in
  that minute carry the old model's id with the new model's vectors, are stale
  after the change and are re-embedded with the rest.
- Rule 2 of `AGENTS.md` is reworded: `ingest/1` writes documents and chunks;
  the re-embed job in `Knowseek.Documents` replaces vectors only. Rule 7 gains
  the partition key.
- A page that always fails to embed stops the job at that page: five attempts,
  then the watch enqueues a new job every minute. The log shows it; nothing
  skips the page.
- A job that crashes mid-run is left `executing` in Oban and blocks nothing;
  the next check enqueues a new one.
- sqlite-vec 0.1.9 never reuses a deleted slot, so forgetting a page frees no
  disk (that is #91's problem); storage order only keeps the re-embed's peak
  small.
- Switching back to a model whose row still exists (before the first switch
  finished) does not move `inserted_at`, so crawl candidates scored in between
  are kept; they are checked again before any fetch.

## Not built

A command (`make reindex`, a Mix task, a release function), a button or an
endpoint that starts or stops a re-embed (#83 for the command); re-cutting pages
and any `chunker_version` or `extractor_version` (#83); int8 vectors (#107); compaction of the
vector table (#91); keeping both sets of vectors; embedding the query twice.
