# 0024. Search: HNSW iterative scan

- Status: Accepted
- Date: 2026-11-04

Related: task [044](../tasks/044-hnsw-recall-after-deletes.md) (the experiment
and the options),
[ADR 0011](0011-one-hit-per-document.md) (the candidate budget and
`hnsw.ef_search`), [ADR 0002](0002-postgres-pgvector.md) (pgvector).

## Context

The vector half of `Knowseek.Search` is `ORDER BY embedding <=> $1 LIMIT
limit * candidate_factor` (400 for `limit` 10), run with `hnsw.ef_search` set
to the same number (ADR 0011). pgvector's HNSW scan takes `ef_search`
candidates from the graph and Postgres then drops the ones whose heap row is
dead. A chunk that was deleted, or replaced by a re-ingest with a changed body
(`Documents.ingest/1` replaces all of a document's chunks), stays in the index
as a dead entry until `VACUUM`. Dead entries use up the candidate budget and
nothing replaces them. If dead look-alikes of a query fill the budget, the
scan returns zero rows, with no error and no log line, and hybrid search
silently becomes keyword-only search for that query.

Task 044 measured this (pgvector 0.8.7, PostgreSQL 17.11, real commits through
`Documents.ingest/1`). The planner uses the index from about 25,000 to 27,500
dense 1024-dimension chunks; below that the query is an exact scan and the
problem does not exist. Above it, 450 dead look-alikes of a deleted document
(1.1% of 40,000 live chunks, no vacuum) made `Search.search/2` return 0 hits
for a query about that document, where the exact scan returned 10. Dead entries
spread evenly shrink the list instead of emptying it (205 of 400 rows at as many
dead as live entries, 21 at 20 times as many) while the nearest live chunk is
still found. Autovacuum starts at `50 + 0.2 * reltuples` dead rows (about 8,000
at 40,000 chunks), so it does not prevent the case. The test suite could not
see any of this: `config/test.exs` turns index scans off (GitHub PR #37).

This ADR's own measurements (same method, scratch databases, the real
`Search.search/2`, committed data, autovacuum off for `chunks`):

- Before the change, on the 40,000-chunk database with 450 dead look-alikes
  (the planner chose the index itself): 0 hits.
- `strict_order` against `relaxed_order`, on 1,000 live look-alike chunks with
  each re-ingested 5 and 20 times (about 5,000 and 20,000 dead entries), 60
  queries, plus 450 dead look-alikes of a deleted document, 20 queries:

  | state | mode | avg rows of 400 | queries with an out-of-order pair | recall@10 | recall@400 | median ms |
  | --- | --- | --- | --- | --- | --- | --- |
  | 20x dead | off | 18.9 | 0/60 | 0.997 | 0.047 | 7.0 |
  | 20x dead | strict | 400 | 0/60 | 0.997 | 0.791 | 78.8 |
  | 20x dead | relaxed | 400 | 60/60 (18 adjacent pairs per query) | 0.997 | 0.98 | 64.5 |
  | 5x dead | off | 65.9 | 0/60 | 1.0 | 0.165 | 7.4 |
  | 5x dead | strict | 400 | 0/60 | 1.0 | 0.937 | 21.0 |
  | 5x dead | relaxed | 400 | 60/60 (5.1 per query) | 1.0 | 0.993 | 19.9 |
  | 450 dead look-alikes | off | 0 (20/20 queries empty) | | 0 | 0 | 5.5 |
  | 450 dead look-alikes | strict | 400 | 0/20 | 1.0 | 1.0 | 11.8 |
  | 450 dead look-alikes | relaxed | 400 | 2/20 | 1.0 | 1.0 | 20.0 |

  With hashing vectors (many exact ties) `strict_order` stepped backwards by
  at most 1e-8 in cosine distance (float noise on ties); `relaxed_order` by up
  to 0.104.

## Decision

1. `Search.with_ef_search/2` also sets `hnsw.iterative_scan = strict_order` and
   `hnsw.max_scan_tuples = 20000` with `set_config(..., true)`, in the same
   statement and transaction that set `hnsw.ef_search`. With an iterative scan,
   a scan that comes up short of `LIMIT` rows keeps walking the graph.
2. Both are config under `config :knowseek, Knowseek.Search`: `iterative_scan`
   (`:strict_order`, the default, or `:off`) and `max_scan_tuples` (a positive
   integer). Any other value raises `ArgumentError`. `Knowseek.Application`
   validates both once at boot, with the same function that every search uses
   (`Search.validate_config!/0`), so a typo stops the start instead of failing
   every search.
3. `strict_order`, not `relaxed_order`. The vector list's rank feeds reciprocal
   rank fusion (rank `i` contributes `1 / (60 + i)`), and the rows are
   consumed in the order the query returns them. `relaxed_order` returned the
   list out of order in every query with dense vectors, and by up to 0.1 in
   cosine distance with hashing vectors: it would need a re-sort in Elixir
   to be safe. `strict_order` returned exact order (to float noise), had the
   same recall@10 as `relaxed_order` in every run, was faster in the
   zero-row case that this ADR is about (11.8 against 20.0 ms, and 33 against
   62 ms through `Search.search/2` at 40,000 chunks, one run each) and 20%
   slower at 20 times as many dead as live entries (78.8 against 64.5 ms), and
   needs no extra code. `relaxed_order` was better in one respect only: the
   tail of the list (recall@400 0.98 against 0.79 at 20 times as many dead as
   live entries, with identical recall@10). The tail feeds grouping and
   `passages` (ADR 0011), and a graph in that state needs a `VACUUM` or
   `REINDEX` anyway.
4. `max_scan_tuples` stays at pgvector's default, 20,000. The cap is what bounds
   the worst case: the walk costs time in proportion to the entries it visits
   (79 ms median at about 20,000 dead entries, against 7 ms without the
   iterative scan). Raising it to 100,000 changed nothing in any run
   (recall and time the same; task 044 saw the same with 1,000,000), so the cap
   was not what limited recall, and a larger one only raises the worst-case time. It is
   config so that an index with more dead entries can trade time for a longer
   list, until a vacuum catches up.
5. The minimum pgvector version is 0.8 (`hnsw.iterative_scan` was added in
   0.8.0). The `pgvector/pgvector:pg17` image in `docker-compose.yml`, which
   development, CI and the release image's database use, has 0.8.x (0.8.7
   when measured). The application checks the installed version at boot, and a
   pgvector below 0.8 does not start (the failure is clear, and nothing is
   swallowed):
   - `Knowseek.Search.PgvectorCheck` is a supervisor child right after
     `Knowseek.Repo`. Unless `iterative_scan` is `:off`, it reads
     `SELECT extversion FROM pg_extension WHERE extname = 'vector'`, compares
     the version as numbers (0.10.1 is above 0.8.7), and fails the start when
     the extension is missing or below 0.8.0, with a message that names
     `iterative_scan: :off` and the minimum. It runs when the application
     starts. `mix ecto.migrate` and `Knowseek.Release.migrate/0` (`bin/migrate`)
     do not start the application, so the migration that runs
     `CREATE EXTENSION vector` is never blocked by it; an application that
     starts on a database without the extension has not been migrated, and the
     message says to run the migrations. Checked by hand on
     `pgvector/pgvector:0.7.4-pg17`: a created but unmigrated database, the
     migrated one (too old), `iterative_scan: :off` (starts), and
     `Release.migrate/0` on a fresh database (runs).
   - Without the check, on pgvector 0.7.4 the
     statement fails with `invalid configuration parameter name
     "hnsw.iterative_scan"` (`"hnsw" is a reserved prefix`), so every search
     fails loudly. Postgres only raises that error once pgvector is loaded in the
     connection. On a fresh connection it logs a warning and drops the setting,
     so that the first search would run unprotected and every later one on that
     connection would fail. The statement therefore reads
     `FROM (SELECT '[0]'::vector)`, which loads pgvector (the cast runs when
     the statement is parsed) before `set_config` runs. Tested on PostgreSQL
     17 with pgvector 0.7.4: the error comes on the first statement of a new
     connection.
   - `iterative_scan: :off` sends only `hnsw.ef_search`, which every pgvector
     with HNSW accepts. It is the way to run on an older pgvector, without the
     protection.
6. A guard test, `test/knowseek/search_hnsw_test.exs` (tag `:hnsw_guard`), runs
   the real HNSW scan on committed data: 520 dead look-alike chunks (a
   20-chunk document ingested 26 times with a changed body, then deleted)
   around one query, and a live set of three related documents. The failure starts at about
   400 dead entries, `ef_search` for `limit: 10` (280 and 360 dead entries
   still found the live chunk, 400 and 420 did not), and the test keeps a
   margin of 30%. With `iterative_scan: :off` it returns no hit (this
   documents pgvector's behaviour: a pgvector that walks past dead entries by
   itself would fail it); with the
   default it returns the live documents, with the exact scan's similarities.
   The live set is three documents with different similarities, and the test
   asserts their order against the exact scan. (A three-row list did not
   show a difference between `strict_order` and `relaxed_order` in five runs,
   so the choice of mode is pinned by the unit test, not by the guard.) It
   is the one exception to "index scans are off in tests" (AGENTS.md,
   "Testing rules"), and isolates itself: its own connection pool outside the
   SQL sandbox, `async: false`, a truncate before and after, autovacuum off
   for `chunks` meanwhile, both undone in `on_exit` (the autovacuum reset first,
   and both steps even if one fails). A run that is killed leaves its rows
   behind until the next run or a `TRUNCATE`.
7. `docs/ARCHITECTURE.md`, "Vector index health", has the `psql` query for dead
   tuples and index size, and the `VACUUM` and `REINDEX` commands with
   measured costs.

## Rejected options

- **A higher `ef_search` alone.** The cap is 1000. At 450 dead look-alikes
  it gave 400 rows (task 044), and 200 at 800. It does not fix 1,000 or more
  dead entries near a query, costs 1.5 to 2 times the query time for every
  query, and `candidate_factor` is capped by the same limit.
- **An exact scan as a fallback or as the only scan** (`enable_indexscan = off`
  for the vector query). It always works, and costs 259 to 515 ms against
  17 to 61 ms through the index at 40,000 to 120,000 chunks, growing linearly.
  The planner already does it below about 25,000 chunks. A fallback ("scan again
  if the list is short") duplicates what the iterative scan does inside the
  index, with a full scan as the price.
- **Autovacuum tuned for `chunks`** (a lower `autovacuum_vacuum_scale_factor`).
  It would keep the dead count small and repair graph quality, but it does not
  help against the entries that exist before a vacuum runs, an HNSW vacuum is
  slow (see Consequences), a long transaction can still hold it back, and the right
  values were not measured at a real size. A per-table setting is a migration.
  Left for a later step, once the monitoring shows the need.
- **`relaxed_order`.** See decision 3.
- **Periodic `REINDEX`.** Needs a scheduler and extra disk and time (about 150 s
  at 40,000 chunks). Not built; the monitoring note says when to run it by hand.

## Consequences

- A search no longer silently loses its vector list to dead entries, up to the
  scan cap. At 40,000 live chunks with 450 dead look-alikes and no vacuum, the
  real `Search.search/2` returns 10 hits with the exact scan's similarities
  (0.757, 0.754, 0.754) instead of 0, in about 16 ms (median of 20) against 259 ms for the
  exact scan. On 30 queries about live documents the hit list was identical to
  the exact scan's in 30 of 30, before and after.
- A clean index costs the same within noise: median 18.2 ms before against 17.5 ms
  after at 40,000 chunks, and 36.8 against 31.4 ms at 120,000 chunks (120 searches
  each, three interleaved rounds). The walk costs time in proportion to the dead
  entries in front of the live ones: about 79 ms at 20,000 dead entries.
- The iterative scan does not repair the graph. Recall of ranks 2 to 10 with
  random vectors at 20 times as many dead as live entries stayed at 0.56 in task
  044; only `VACUUM` or `REINDEX` restored it. Autovacuum may still run late under
  heavy churn (8 times as many dead as live entries after 72 s of continuous
  churn in task 044).
- Above `max_scan_tuples` (20,000) dead entries in front of a query the list can
  still come back short ([INFERENCE]: the cap is pgvector's, and this was not
  measured above 20,000).
- Repair costs, measured on this machine: `VACUUM chunks` 0.3 s for 450 dead
  entries among 40,000 chunks, 11 s for 5,000 dead entries among 1,000 chunks;
  `REINDEX INDEX CONCURRENTLY` 150 s for 40,000 chunks (313 MB, default
  `maintenance_work_mem`).
- A pgvector older than 0.8 needs `iterative_scan: :off`. The docker image tag
  is not pinned to a minor version, so a future `pg17` tag moves forward, not
  back. The minimum is documented here and in `docs/ARCHITECTURE.md`; the
  compose file is unchanged. The application does not start on an older one
  unless `iterative_scan: :off` is set (decision 5).
- The guard test takes a few seconds (about 2 to 8 s depending on the machine)
  and locks `chunks` and `documents` (truncate) while it runs; it is the only
  test that does.
- `limit` above 25 (more than 1,000 candidates, `ef_search` capped at 1000) was
  not measured with the iterative scan; the worst case is bounded by
  `max_scan_tuples` ([INFERENCE]).
- Not measured: real Ollama embeddings, dead entries above 40,000 chunks,
  concurrent writers during a search, long transactions that hold vacuum back.
