# 044. Semantic search can lose live chunks to dead HNSW entries

- Status: done
- Area: `Knowseek.Search`, `Knowseek.Documents`, Postgres/pgvector config
- Depends on: none

## Goal

Make the vector half of `Knowseek.Search` return the live nearest chunks even when many deleted or replaced chunks are still in the HNSW index, and make a regression of that visible. Today, a test-suite flake (PR #37) showed the mechanism, and production has the same mechanism.

## Context

- `Documents.ingest/1` replaces a document's chunks when its body changes (`replace_chunks/2`: `delete_all`, then `insert_all`). A document delete cascades to its chunks. Every removed chunk leaves a dead entry in `chunks_embedding_vector_cosine_ops_index` (HNSW, cosine) until `VACUUM` (usually autovacuum) removes it.
- The vector query is `ORDER BY embedding <=> $1 LIMIT limit * candidate_factor` (10 * 40 = 400), in a transaction that sets `hnsw.ef_search` to the same number (`Search.with_ef_search/2`, ADR 0011).
- An HNSW scan gets `ef_search` candidates from the graph, then Postgres drops the ones whose heap row is dead. Dead entries use up the candidate budget and no row replaces them. If the budget is all dead rows, the query returns zero rows. Nothing raises an error or logs a warning.
- PR #37 found this in the test suite: every test rolls back its inserts, the dead entries stay, the planner switched from `Seq Scan` + `Sort` to the HNSW `Index Scan` (even with one live row), and the index scan returned zero rows for a new, different vector. It fixed the tests with `enable_indexscan: "off"` in `config/test.exs`. Production still uses the index scan, and no test exercises it.
- pgvector 0.8 added iterative index scans (`hnsw.iterative_scan` = `off` | `strict_order` | `relaxed_order`, bounded by `hnsw.max_scan_tuples`, default 20,000): when the scan has fewer rows than `LIMIT`, it continues in the graph. The Postgres image in `docker-compose.yml` is `pgvector/pgvector:pg17`. The experiment ran on pgvector 0.8.7 and PostgreSQL 17.11 (`SELECT extversion FROM pg_extension WHERE extname='vector'`).

## Evidence

One experiment, on one machine (Apple silicon, 8 cores, the shared Docker Postgres with default settings: `shared_buffers` 128 MB, autovacuum on, naptime 1 min, scale factor 0.2). It is synthetic. Several runs shared the CPU, so absolute milliseconds are noisy (about +-30%); compare rows and recall, and the order of magnitude of the times. The scripts are in the description of the PR that added this task; they are not committed.

Method: a scratch database made from the repo's migrations (`mix ecto.migrate`), the real code path with real commits (`Documents.ingest/1` for every insert and re-ingest, `Repo.delete_all` on documents for deletes; no rolled-back transactions). Autovacuum was switched off for the table (`ALTER TABLE chunks SET (autovacuum_enabled = false)`) for the worst-case runs, and left on for one separate run. The exact answer is the same SQL with `enable_indexscan = off`. Queries are made from live documents (a perturbed live vector, or ten words of the live body for hashing), 60 against old documents and 30 against documents ingested after the churn. The tables show the first group.

Three vector models:

- `hashing`: the repo's `Knowseek.Embeddings.Hashing` on synthetic word-bag bodies (a re-ingest changes 4 words of 29, so old and new versions are look-alikes).
- `look-alike`: synthetic dense 1024-dimension unit vectors (a topic centre plus a per-document offset; versions of one document differ by small noise, cosine about 0.99). Closest to real model vectors of the three, though not real.
- `random`: independent 1024-dimension Gaussian unit vectors per version. Dead entries are not look-alikes. Only the top-1 is meaningful here, because every other chunk is at cosine about 0 to the query, so recall@10 mostly measures graph quality.

### 1. Which scan does the planner pick?

The HNSW scan only matters if the planner picks it. Dense look-alike vectors, never churned, `ANALYZE` run, the production query (`LIMIT 400`, `ef_search` 400):

| live chunks | plan | planner cost, seq scan | planner cost, index scan |
| --- | --- | --- | --- |
| 2,500 to 25,000 | Seq Scan + Sort | 211 to 2,084 | 10,065 (2,500) to 2,228 (25,000) |
| 27,500 | Index Scan | higher than the index (not printed) | 2,284 |
| 30,000 to 120,000 | Index Scan | higher than the index (not printed) | 2,340 to 4,378 |

So with dense 1024-dimension vectors, an exact scan is used below about 25,000 to 27,500 chunks, and the HNSW index is used above it. The `chunks` heap is small because `vector(1024)` is stored out of line (TOAST, `attstorage = e`), so the planner sees few pages. With the `hashing` adapter, the planner chose the index scan on a 1,030-row table after one round of re-ingests (the dead rows made the table 12 MB), and kept it at 5x and 20x. I did not find out why the two models differ here.

Search latency on a clean 120,000-chunk index through `Knowseek.Search.search/2` (20 queries, limit 10): median 61 ms with the index (max 97), 515 ms with an exact scan (`enable_indexscan = off`; max 720), 47 ms with `relaxed_order`, 42 ms with `strict_order`. The top hits were the same in all four.

### 2. Dead entries spread evenly (every document re-ingested n times)

1,000 live documents (one chunk each), re-ingested 1, 5, and 20 times with a changed body: 1x, 5x, and 20x as many dead entries as live ones. "Candidates" is how many of the 400 requested rows the scan returned. The index scan is forced (`enable_seqscan = off`) where the planner picked an exact scan, so that these rows show the index behaviour. "Top-1" counts queries whose exact nearest live chunk is in the first 10 returned. Recall@10 is the share of the exact top 10 found in the first 10 returned. Times are medians per query.

look-alike vectors:

| state | planner chose | candidates (of 400) | top-1 | recall@10 | ms | `ef_search` 1000: candidates / recall@10 | `relaxed_order`: candidates / recall@10 / ms |
| --- | --- | --- | --- | --- | --- | --- | --- |
| fresh | Seq Scan | 400 | 60/60 | 1.0 | 9.2 | 400 / 1.0 | 400 / 1.0 / 10.9 |
| 1x dead | Seq Scan | 205 | 60/60 | 1.0 | 9.0 | 400 / 1.0 | 400 / 1.0 / 13.0 |
| 5x dead | Seq Scan | 71 | 60/60 | 1.0 | 12.7 | 178 / 1.0 | 400 / 1.0 / 36.5 |
| 20x dead | Seq Scan | 21 | 59/60 | 0.998 | 7.2 | 52 / 1.0 | 400 / 0.998 / 83.2 |
| after `VACUUM chunks` | Seq Scan | 400 | 60/60 | 1.0 | 7.4 | 400 / 1.0 | 400 / 1.0 / 8.6 |

random vectors:

| state | planner chose | candidates (of 400) | top-1 | recall@10 | ms | `ef_search` 1000: candidates / recall@10 | `relaxed_order`: candidates / recall@10 / ms |
| --- | --- | --- | --- | --- | --- | --- | --- |
| fresh | Seq Scan | 400 | 60/60 | 1.0 | 8.3 | 400 / 1.0 | 400 / 1.0 / 10.8 |
| 1x dead | Seq Scan | 206 | 60/60 | 1.0 | 9.5 | 400 / 1.0 | 400 / 1.0 / 11.9 |
| 5x dead | Seq Scan | 69 | 60/60 | 0.932 | 14.9 | 177 / 0.995 | 400 / 0.932 / 23.8 |
| 20x dead | Seq Scan | 18 | 60/60 | 0.56 | 24.2 | 46 / 0.828 | 400 / 0.56 / 73.5 |
| after `VACUUM chunks` | Seq Scan | 400 | 60/60 | 1.0 | 7.6 | 400 / 1.0 | 400 / 1.0 / 8.2 |

hashing vectors (the planner chose the index scan itself from 1x on, so the first columns are what a default setup does):

| state | planner chose | candidates (of 400) | top-1 | recall@10 | ms | `ef_search` 1000: candidates / recall@10 | `relaxed_order`: candidates / recall@10 / ms |
| --- | --- | --- | --- | --- | --- | --- | --- |
| fresh | Seq Scan | 400 | 60/60 | 0.983 | 9.5 | 400 / 0.98 | 400 / 0.983 / 11.5 |
| 1x dead | Index Scan | 204 | 60/60 | 0.977 | 10.5 | 400 / 0.968 | 400 / 0.977 / 12.7 |
| 5x dead | Index Scan | 70 | 60/60 | 0.972 | 15.8 | 176 / 0.968 | 400 / 0.972 / 43.6 |
| 20x dead | Index Scan | 21 | 59/60 | 0.938 | 11.3 | 51 / 0.968 | 400 / 0.938 / 136.6 |
| after `VACUUM chunks` | Seq Scan | 400 | 60/60 | 0.98 | 7.8 | 400 / 0.983 | 400 / 0.98 / 8.8 |

Reading: with evenly spread dead entries, the live nearest chunk is still found (top-1 59/60 or 60/60 everywhere), and no query returned zero rows. What shrinks is the candidate list: about 400 / (1 + dead per live) rows come back. The recall of ranks 2 to 10 holds for clustered vectors and falls for random vectors at 20x. `relaxed_order` fills the list back to 400 but does not change recall@10 here (the first rows are the same), and it costs time in proportion to the dead entries it walks through: about +1 to +3 ms on a clean index, up to about 80 to 140 ms at 20x (about 20,000 dead entries; `hnsw.max_scan_tuples` caps the walk; raising it to 1,000,000 gave the same numbers). Raising `ef_search` to 1000 helps recall and the candidate count in part and costs 1.5 to 2 times the query time. `VACUUM chunks` restores everything. The same run on the 20x state with `REINDEX INDEX CONCURRENTLY` (no vacuum; the table still had 20,000 dead rows) shrank the index from 164 MB to 8.2 MB and gave 400 candidates and recall@10 1.0.

### 3. Dead entries concentrated near one query

One document X re-ingested n times, then deleted: n dead look-alikes of X and no live copy. The query is about X's old content, and the best live answer is a related document. 1,000 live documents in the first block. The index scan is forced where the planner picked an exact scan. 20 queries per row.

| model | dead look-alikes | candidates (of 400) | queries with zero rows | top-1 found | `ef_search` 1000 candidates | `relaxed_order` candidates / ms (index scan: ms) |
| --- | --- | --- | --- | --- | --- | --- |
| look-alike | 100 | 300 | 0/20 | 20/20 | 400 | 400 / 9.9 (7.9) |
| look-alike | 300 | 100 | 0/20 | 20/20 | 400 | 400 / 9.6 (6.6) |
| look-alike | 450 | 0 | 20/20 | 0/20 | 400 | 400 / 8.7 (4.3) |
| look-alike | 800 | 0 | 20/20 | 0/20 | 200 | 400 / 9.2 (5.0) |
| hashing | 100 | 301 | 0/20 | 20/20 | 400 | 400 / 10.6 (8.3) |
| hashing | 300 | 107 | 0/20 | 20/20 | 400 | 400 / 11.7 (8.0) |
| hashing | 450 | 0 | 20/20 | 0/20 | 400 | 400 / 9.2 (4.7) |
| hashing | 800 | 0 | 20/20 | 0/20 | 203 | 400 / 9.6 (5.5) |

The candidate count is about 400 minus the dead look-alikes that are nearer than the live match: the zero-row case starts when the dead entries near the query reach `ef_search` (400). The exact scan returned the live related document first in every case.

Dead entries of a document that is still live, as `Documents.ingest/1` leaves them. 2 documents re-ingested 500 times each among 1,000 live ones (1,000 dead entries, index scan forced), queries about those 2 documents: 1 candidate of 400 came back, recall@10 0.1 (the live nearest chunk was found in all 60 queries, nothing behind it). `ef_search` 1000 gave 313 candidates and recall 1.0; `relaxed_order` gave 400 and 1.0 (13.6 ms against 6.7). 20 documents re-ingested 100 times each (2,000 dead entries): 129 candidates, recall@10 1.0 (400 and 1.0 with `relaxed_order`). Queries about the other documents in the same two states returned 262 and 146 candidates.

The same test at the size where the planner chooses the index by itself: 40,000 live chunks (look-alike vectors, a fresh index), X re-ingested 450 times and deleted. That is 450 dead entries, 1.1% of the live count, and no vacuum has run:

| | candidates (of 400) | zero-row queries | top-1 found |
| --- | --- | --- | --- |
| planner's plan (Index Scan, `ef_search` 400: production) | 0 | 20/20 | 0/20 |
| `ef_search` 1000 | 400 | 0/20 | 20/20 |
| `relaxed_order`, `strict_order` | 400 | 0/20 | 20/20 |

Through `Knowseek.Search.search/2` on that database (query text equal to X's vector, `limit` 10, no keyword match): production configuration, 0 hits (37 ms); exact scan (`enable_indexscan = off`), 10 hits, best similarity 0.757 (389 ms, one call); `hnsw.iterative_scan = relaxed_order`, 10 hits, same similarities (52 ms); `strict_order`, 10 hits (34 ms).

Documents that are re-ingested concentrate dead entries in their own neighbourhood: a 35-chunk document whose body changes 12 times leaves about 420 dead entries around the topic. Live chunks of the same document are near the same queries, so that case looks like section 2 and the live-document runs above (a candidate list of about 400 / (1 + dead per live chunk), with the nearest live chunk still found). The zero-row case needs the dead entries to be nearer than every live chunk, as when a page is deleted or rewritten to say something else.

### 4. What autovacuum does

With default autovacuum, continuous churn (1,000 chunks replaced every 8 to 9 s, about 110 per second, 1,000 live): `n_dead_tup` reached 7,977 (8x the live count) at 72 s, and the first autovacuum had finished by 83 s. It ran 3 times in 242 s. `n_dead_tup` moved between about 2,000 and 8,000 (2x to 8x live). In the samples taken at 83, 165, and 242 s (3,042, 4,621, and 6,038 dead), the forced index scan returned 100, 74, and 63 candidates of 400, with top-1 found for all 60 queries and recall@10 1.0 each time; the planner stayed on the exact scan. Autovacuum's trigger is `50 + 0.2 * reltuples` dead rows: at 1,000 live that is 250; at 40,000 live, 8,050; at 120,000 live, 24,050. A large table can therefore hold thousands of dead entries before autovacuum starts, and the zero-row case needs only about 400 of them near one query.

### Limits of the evidence

- Synthetic data. The hashing vectors have no semantics, the look-alike and random vectors are made up, and there are no real Ollama embeddings. The planner switch point (about 25,000 to 27,500 chunks) and the graph behaviour depend on the vectors and on `ef_search`; I measured them only for these.
- One machine, one Postgres configuration, one pgvector version (0.8.7). Runs overlapped in time.
- Dead-entry counts come from the number of re-ingests; `n_dead_tup` is an estimate from the statistics collector and was lower than the true count in the concentrated runs (Postgres prunes dead rows on access).
- Up to 40,000 live chunks for the dead-entry runs, and 120,000 for the clean-index latency run. Not measured: dead entries in a large table at the planner's switch point and above, other `limit` values, concurrent writers during the query, how long `VACUUM` and `REINDEX` take on a large index, long-running transactions that hold back vacuum (standard Postgres behaviour, not tested here), and real documents (a 35-chunk article).

## Findings

- There is a production risk, and it is conditional. All three conditions are needed:
  1. The planner uses the HNSW scan. With dense 1024-dimension vectors, that starts at about 25,000 to 27,500 chunks. Below it the query is an exact scan and the risk does not exist. With the `hashing` adapter (dev or opt-out), bloat from dead rows makes the planner choose the index much earlier.
  2. There are dead entries near the query. With 1x dead entries, the semantic list is about half full; at 5x about 70 rows of 400; at 20x about 20 rows. The live nearest chunk was still found (top-1 59/60 or 60/60), so the head of the list is right. The tail is lost, and the tail feeds `candidate_factor` grouping and `passages` (ADR 0011).
  3. For zero rows, dead entries near the query must reach `ef_search` (400) with no nearer live chunk, and that was reproduced at 450 dead look-alikes in a 40,000-chunk index (1.1% dead). It silently turns hybrid search into keyword-only search for that query.
- [INFERENCE] When the semantic list is empty and the keyword list also finds nothing, `Search` returns no hits, coverage is `:none`, and `Lookup` requests discovery for a query the index already answers. I did not run that path.
- Autovacuum already removes dead entries, but late: the default trigger is 20% of the table, so the allowed number of dead entries grows with the index, and HNSW vacuum is slow enough that dead entries reached 8x live under heavy churn.
- `hnsw.iterative_scan` fixes the failure that matters most (an empty or short list) at a small cost on a clean index (+1 to +3 ms) and a cost that grows with the dead entries it has to walk through (about 80 to 140 ms at 20,000 dead entries; bounded by `hnsw.max_scan_tuples`). It does not repair graph quality, so recall of ranks 2 to 10 with random vectors at 20x dead stayed at 0.56; only `VACUUM` or `REINDEX` restored it.
- Both `relaxed_order` and `strict_order` returned a full list in every run. In one run (hashing vectors, 800 dead look-alikes, 20 queries) `strict_order` found the exact top-1 in 16 of 20 queries against 20 of 20 for `relaxed_order`; I did not repeat it.
- The test suite does not cover any of this: it runs with `enable_indexscan: "off"`.

## Options

| Option | Fixes | Costs and limits |
| --- | --- | --- |
| Do nothing and monitor | Nothing. | Zero-row and short semantic lists stay possible above about 25,000 chunks, and nobody sees them. Monitoring (`n_dead_tup`, last autovacuum) tells you the dead count, not the lost recall. |
| `hnsw.iterative_scan = relaxed_order` in `with_ef_search/2` (`set_config(..., true)`) | The empty or short candidate list, including the zero-row case. Used only when the scan comes up short, so little cost on a clean index. | Recall of ranks 2 to 10 is unchanged when the graph is bad. Cost grows with dead entries (about 80 to 140 ms at 20,000, bounded by `hnsw.max_scan_tuples`). Order can be slightly off (`relaxed`). Needs pgvector 0.8 or later; [INFERENCE] an older image would reject or ignore the setting (not tested). |
| `strict_order` | The same, with exact order. | In one run (hashing, 800 dead look-alikes) it found the top-1 in 16 of 20 queries against 20 of 20 for `relaxed_order`; not repeated. Same time cost in my runs. |
| A higher `ef_search` (the cap is 1000) | Partly: 400 to 1000 gave 20 to 52 candidates at 20x instead of 18 to 21, and 400 candidates at 450 dead look-alikes, not at 800 (200 candidates). | 1.5 to 2 times the query time. Does not fix 1,000 or more dead entries near a query. A bigger `candidate_factor` is capped by the same 1000 limit. |
| Autovacuum tuned for `chunks` (lower `autovacuum_vacuum_scale_factor`, for example 0.02, and a small `autovacuum_vacuum_threshold`) | Keeps the dead count small so the other problems rarely appear, and repairs graph quality. | More vacuum runs; HNSW vacuum is slow on a large index. A long transaction can still hold vacuum back. It does not fix the entries that exist before a vacuum runs. The right values are untested here. A per-table setting is a migration. |
| Periodic `REINDEX INDEX CONCURRENTLY` (and `VACUUM`) | Everything, until the next batch of deletes (20x state: index 164 MB to 8.2 MB, recall 1.0). | Needs a scheduler (an Oban cron job) and extra disk and time while it builds; build time on a large index was not measured. |
| An exact scan below a size threshold (`enable_indexscan = off` per query, or always) | The planner already does this below about 25,000 chunks; forcing it above removes the risk. | Linear time: 515 ms median at 120,000 chunks against 61 ms with the index. A threshold in code duplicates the planner. Only viable for a small index. |

## Recommendation

Treat it as a real, narrow risk and fix it in layers, cheapest first:

1. Set `hnsw.iterative_scan = relaxed_order` in `Search.with_ef_search/2`, in the same transaction that sets `ef_search`. This is the only option in the list that removes the silent empty list at a small cost. Keep `hnsw.max_scan_tuples` at its default (20,000) unless the implementation measures a reason to change it. Decide between `relaxed_order` and `strict_order` with the test below, not from my one run.
2. Add a guard test that exercises the HNSW path with committed data (see Scope), so that a future change cannot bring the empty list back without a test failing. The tests run with `enable_indexscan: "off"` today.
3. Write down a monitoring query for `chunks` (`n_dead_tup`, `last_autovacuum`, the index size). Tune autovacuum for `chunks` in a later step, with measured vacuum times on a real-size index, not on my numbers.

Not recommended now: forcing an exact scan, and periodic `REINDEX` (add it if the monitoring shows dead entries piling up).

## Scope

- `Knowseek.Search`: set `hnsw.iterative_scan` with `set_config('hnsw.iterative_scan', ..., true)` in `with_ef_search/2`; update the comment and ADR 0011's description of the vector query (the "short transaction" consequence) if its facts change. State the minimum pgvector version (0.8) next to the image tag in `docker-compose.yml`, and check what an older pgvector does with the setting.
- A test that fails without the setting. It needs committed data, because rolled-back inserts bloat the shared test database (the cause of PR #37). Options: a test that checks out its own connection outside the sandbox on a scratch table with the same HNSW index (`CREATE TEMP TABLE` with `embedding vector(1024)` and an HNSW cosine index, then the same query shape as `semantic_matches/2` and the same `set_config` calls), or a database created and dropped by the test. It must run the index scan on purpose (`enable_seqscan = off` for that connection), create at least `ef_search` (400) dead look-alike entries (insert and delete rows, no vacuum), and clean up after itself (`VACUUM FULL`, `REINDEX`, or drop). Assert that the query without the setting returns fewer rows than the exact answer, so the test shows the problem and not only the fix.
- A monitoring note, in `docs/DATA-AND-JOBS.md` if it has landed (PR #31), otherwise in the Deployment section of `docs/ARCHITECTURE.md`: the query for `pg_stat_user_tables.n_dead_tup`, `last_autovacuum`, and `pg_relation_size('chunks_embedding_vector_cosine_ops_index')`, what a large `n_dead_tup` means for search, and the commands `VACUUM chunks` and `REINDEX INDEX CONCURRENTLY chunks_embedding_vector_cosine_ops_index`. Optional: show the same figures in the job dashboard or as telemetry.
- Re-run the experiment's concentrated-dead-entries case (section 3) against the changed `Search` and put the numbers in the Outcome section, at about 40,000 chunks so that the planner picks the index by itself.
- Update the "Search tests that load many chunks" paragraph in the Testing rules of `AGENTS.md` if the new test changes what it says. Do not change `enable_indexscan: "off"` in `config/test.exs` for the other tests.

## Acceptance criteria

- A test fails on the current `Search` and passes with the change: with at least 400 dead look-alike entries near the query and one live, different vector, the HNSW scan returns that live vector.
- With the change, the section 3 case on a 40,000-chunk index returns the live related document through `Search.search/2` (it returned 0 hits before).
- The monitoring query and the manual repair commands are documented, and the documented query runs against a migrated database.
- The latency of a clean-index search at 40,000 and at 120,000 chunks is within noise of the numbers above (about 60 ms median at 120,000), measured with and without the change.
- `make check-quiet` passes.

## Out of scope

- Changing the vector size, the model, or the index type or parameters (`m`, `ef_construction`). Those need a migration and a re-embed plan (ADR 0004, task 017).
- Grouping hits by document in SQL (task 023) and changing `candidate_factor`.
- Running `VACUUM` or `REINDEX` from the application.
- A scheduler for periodic `REINDEX` (a follow-up task if the monitoring shows a need).

## Outcome

Built (ADR [0024](../decisions/0024-hnsw-iterative-scan.md)):

- `Search.with_ef_search/2` sets `hnsw.iterative_scan` and `hnsw.max_scan_tuples` in the same `set_config` statement as `hnsw.ef_search`. Config `config :knowseek, Knowseek.Search`: `iterative_scan: :strict_order` (or `:off`) and `max_scan_tuples: 20_000`; any other value raises `ArgumentError`.
- `strict_order`, not `relaxed_order`: the vector list's rank feeds RRF, and `relaxed_order` returned it out of order for every dense-vector query (and by up to 0.104 cosine distance with hashing vectors); `strict_order` was exact, with the same recall@10. `max_scan_tuples` stays at 20,000: 100,000 changed nothing in any run, and the cap bounds the worst-case time.
- The minimum is pgvector 0.8. On 0.7.4 (the `pgvector/pgvector:0.7.4-pg17` image) the setting fails with `invalid configuration parameter name "hnsw.iterative_scan"`, so every search fails loudly. On a fresh connection Postgres only warns and drops an unknown `hnsw.*` setting until pgvector is loaded, so the statement selects `FROM (SELECT '[0]'::vector)` to load it first. `iterative_scan: :off` sends only `ef_search` and works on an older pgvector.
- Guard test `test/knowseek/search_hnsw_test.exs` (tag `:hnsw_guard`): committed rows through `Documents.ingest/1`, 520 dead look-alike entries (a 20-chunk document ingested 26 times, then deleted), the index scan forced on its own connection pool only. It asserts that the exact scan finds the live document, that `iterative_scan: :off` (the old query) returns no hit, and that the default returns the live document with the exact scan's similarity. With the default config set to `:off` the test fails. The failure starts at about 400 dead entries (280 and 360 found the chunk, 400 and 420 did not). Runtime 3 to 8 s (11 s once, with a 120,000-chunk ingest running next to it). AGENTS.md "Testing rules" names it as the one exception and lists how it isolates itself. `config/test.exs` is unchanged.
- Unit tests in `search_test.exs` for the settings, `:off`, and the invalid config.
- `docs/ARCHITECTURE.md`: "Vector index health" (psql queries for dead tuples and index size, `VACUUM chunks`, `REINDEX INDEX CONCURRENTLY`, measured costs), the config keys, and the known limitation. `docs/DATA-AND-JOBS.md` does not exist on `origin/main`, so the note is only in ARCHITECTURE. ADR 0011's consequence line points to ADR 0024.

Measured on this machine (pgvector 0.8.7, PostgreSQL 17.11, scratch databases, the real `Search.search/2`, committed data, autovacuum off for `chunks`):

| | before (`:off`) | after (`strict_order`) |
| --- | --- | --- |
| 40,000 chunks, 450 dead look-alikes, planner's own Index Scan, query about the deleted document | 0 hits (0 in 20 of 20 queries) | 10 hits in 20 of 20 queries, similarities 0.757, 0.754, 0.754 as the exact scan; median 15.6 ms (exact scan: 259 ms) |
| 30 queries about live documents at 40,000 chunks, same state | identical to the exact scan in 30 of 30 | identical in 30 of 30 |
| clean index, 40,000 chunks, 120 searches in 3 interleaved rounds | median 18.2 ms, p90 30.6 | median 17.5 ms, p90 21.1 |
| clean index, 120,000 chunks (451 dead rows, 1 vacuum earlier), same method | median 36.8 ms, p90 69.4 | median 31.4 ms, p90 51.3 |
| 1,000 chunks re-ingested 20 times (about 20,000 dead entries), 60 queries | 18.9 of 400 rows, 7.0 ms | 400 rows, 78.8 ms |

The section 2 and section 3 numbers of this task did not change except where the table says so. The clean-index latency is within noise of the old figure (about 60 ms at 120,000 in the first experiment; 31 to 37 ms on this run).

Repair costs: `VACUUM chunks` 0.3 s for 450 dead entries among 40,000 chunks, 11 s for 5,000 dead entries among 1,000 chunks; `REINDEX INDEX CONCURRENTLY` 150 s for 40,000 chunks (313 MB, default `maintenance_work_mem`).

Left out:

- Autovacuum tuning for `chunks` (out of scope here, as the task says: it needs vacuum times on a real-size index) and a scheduled `REINDEX`. Neither is needed yet, and the monitoring note says when to act. No follow-up task file was added.
- The iterative scan does not repair graph quality: recall of ranks 2 to 10 at 20 times as many dead as live entries is restored only by `VACUUM` or `REINDEX`.
- Not measured: dead entries above 20,000 near one query (the `max_scan_tuples` cap), above 40,000 chunks, real Ollama embeddings, concurrent writers, long transactions that hold vacuum back.
- The `Lookup` path (`[INFERENCE]` in Findings: an empty semantic list plus no keyword match asks for discovery) was not run.
