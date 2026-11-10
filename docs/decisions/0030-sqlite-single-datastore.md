# 0030. SQLite as the single datastore

- Status: Accepted
- Date: 2026-11-10

Supersedes [0002](0002-postgres-pgvector.md) and
[0024](0024-hnsw-iterative-scan.md); amends
[0005](0005-per-workspace-databases.md). Related: issues
[#80](https://github.com/williamge/knowseek/issues/80) (this change),
[#58](https://github.com/williamge/knowseek/issues/58) (local-first),
[#79](https://github.com/williamge/knowseek/issues/79) (scale), the SQLite
spike in [local-first-sharing.md](../notes/local-first-sharing.md#spike-results-sqlite)
and [local-storage-and-sync.md](../notes/local-storage-and-sync.md#input-for-80).

## Context

[ADR 0002](0002-postgres-pgvector.md) put documents, full-text search, vectors
and jobs in one Postgres database with pgvector. That needs a Docker container
for development, tests and CI, and it stands between Knowseek and a local-first
app that someone can just install (#58, #80).

The index is small (303 chunks in the owner's database) and one instance
serves one user. The two research notes measured SQLite for this workload:

- sqlite-vec scans every vector. At 100,000 chunks and the app's 400
  candidates it took 173 to 240 ms on the stable 0.1.9. Postgres scans exactly
  there too, because the planner does not pick HNSW at 400 candidates, and
  took 237 to 455 ms.
- On 12 queries the vector lists were identical to pgvector's, and the top-5
  documents were the same in 11.
- `Oban.Engines.Lite` passed the worker's options. Five concurrent ingests
  succeeded when every transaction started in immediate mode.

HNSW brought its own cost: dead index entries could silently empty the vector
list ([ADR 0024](0024-hnsw-iterative-scan.md)), and tests had to turn index
scans off.

## Decision

1. **One SQLite file per instance**, through `ecto_sqlite3` (exqlite), in WAL
   mode, with a 5 s busy timeout and a 64 MB `journal_size_limit`. Postgres,
   `postgrex` and `pgvector` are removed. There is no second adapter and no
   Postgres fallback. Dev and test use `backend/data/knowseek_dev.db` and
   `knowseek_test.db` in each checkout (git-ignored); `DATABASE_PATH`
   replaces the path, and the release requires it.
2. **Vectors** live in a sqlite-vec `vec0` table, `chunk_vectors`:
   `float[1024]`, cosine distance, exact scan. The extension is the stable
   v0.1.9 loadable build from the project's GitHub release (the hex package is
   frozen). `mix sqlite_vec.fetch` downloads it into `priv/sqlite_vec/`, checks
   the archive against a pinned SHA-256 (the `digest` GitHub publishes), and
   does nothing when it is there; `setup`, `test` and `ecto.migrate` run it
   first, and the image builder runs it. Pinned builds: macOS arm64 (dev),
   Linux x86_64 (CI) and Linux aarch64 (the image on an arm64 host).
   `Knowseek.Repo` loads it into every connection. Vectors are bound as BLOBs
   (float32, little-endian; `Knowseek.Documents.Vector`): a TEXT value is read
   as a JSON array.
3. **Full text** is an FTS5 external-content table, `chunks_fts`, over
   `chunks.content`, with the `porter unicode61 remove_diacritics 0`
   tokenizer, ranked by `bm25`. Both search tables key on `chunks.seq`, an
   `INTEGER PRIMARY KEY` beside the UUID `id` (a `VACUUM` may renumber an
   implicit rowid, never this one). Triggers on `chunks` keep them in step on
   insert, update and delete, also when a document delete cascades.
   `Documents.ingest/1` stays the only writer (rule 2): it inserts the chunks
   with `RETURNING seq, position` and then their vectors, in the same
   transaction, after embedding (rule 5).
4. **`Knowseek.Search.FtsQuery`** builds the FTS5 query; user text never
   reaches FTS5 as syntax (raw `what's new...` is a syntax error there). It
   reads the query as `websearch_to_tsquery` did: words split as `unicode61`
   splits them, each double-quoted and ANDed; Postgres's English stop words
   (`english.stop`, 127 words) dropped outside phrases; `"a phrase"` kept
   whole; `or` as OR, binding tighter than AND; `-word` and `-"a phrase"` as
   NOT. A query with nothing left (only stop words or exclusions) has no
   keyword list. Fusion stays reciprocal rank fusion in Elixir
   ([ADR 0003](0003-hybrid-search.md)); only rank positions and "has a
   keyword hit" reach the result, so the change of score function does not
   change the API.
5. **Jobs** run on `Oban.Engines.Lite`. Every transaction starts IMMEDIATE
   (`default_transaction_mode: :immediate`): a deferred transaction that reads
   and then writes fails with "database busy" when another writer got in
   between. `Discovery.request/1` inserts its unique job inside a
   transaction, because the Lite engine checks uniqueness and inserts in two
   statements.
6. **A new baseline migration** (`priv/repo/migrations/*_sqlite_baseline.exs`)
   creates today's whole schema, Oban's tables included; the nine Postgres
   migrations are deleted (they stay in git history). UUIDs and timestamps are
   TEXT, `metadata` and `attribution` JSON TEXT, `share` keeps its named CHECK.
   Existing Postgres data is not converted: it is discovered again.
7. **Tests that use the database are not async.** The SQL sandbox holds a
   transaction, IMMEDIATE and so with the write lock, for a whole test, so two
   owners at once would wait on each other; `DataCase` gives an async test no
   connection at all, so a database call there fails loudly.

### The migration round trip across the baseline

`scripts/check-migration-roundtrip` (CI job `migrations`) runs on a temporary
SQLite file (`DATABASE_PATH`). Phase A is unchanged: migrate an empty
database, roll back the added migrations (here the baseline, so everything),
migrate again, run the seeds. Phase B (migrate a database that holds the base
branch's data) needs a database the base branch can create, and a base on
Postgres cannot create one this branch can migrate. So the script skips
Phase B, and says so, when the branch deletes migrations that the base has:
replacing the history is then the point, not an accident. Once this is on
`main`, the base is SQLite too and Phase B runs again for every later
migration, with the base checkout pointed at the same file and given a copy
of the sqlite-vec build.

### What changes elsewhere

- ADR 0024 is superseded: the HNSW scan settings (`iterative_scan`,
  `max_scan_tuples`, `hnsw.ef_search`), `Knowseek.Search.PgvectorCheck`, the
  `:hnsw_guard` test and the test database's `enable_indexscan: "off"` are
  deleted. Its measurements stay as history.
- ADR 0005 is amended: every checkout still has its own databases, now as
  files in its own `backend/data/`, so nothing is named from
  `KNOWSEEK_WORKSPACE` and `make worktree-rm` drops nothing.
  `KNOWSEEK_WORKSPACE` only names the compose app container's image and file.
- `docker-compose.yml` keeps only the `app` service (profile `app`), with the
  file in the `appdata` volume. Makefile targets `db-up` and `db-down` are
  gone; nothing in development, tests or CI runs Docker except the image
  build and gitleaks.

## Consequences

- No Docker for development, tests or CI. CI's `backend` and `migrations`
  jobs have no service container.
- The vector list is always exact. No dead entries, no vacuum, no index health
  to watch.
- Search time grows linearly with the chunk count. Past about 100,000 chunks
  it needs int8 vectors or an approximate index (#79). The vector list is
  capped at 4,096 candidates (sqlite-vec's `k` limit), which only a `limit`
  above 102 reaches (the API allows 50).
- Keyword ranking changes. `bm25` weights rare terms and normalises for
  length, `ts_rank_cd` did neither. FTS5's Porter stemmer is not Postgres's
  Snowball English stemmer: it does not match "octopus" to "octopuses", and
  it stems "news" to "new". The parity run of #80 (40 Wikipedia articles,
  17 queries, bge-m3) found identical vector lists, identical keyword hit sets
  in 15 of 17 queries, the same top-5 documents in 16 and the same order in
  15; both differences were neighbours swapping or the fifth hit changing on
  one-word or OR queries.
- One writer at a time. Transactions must stay short and must not call
  external services (rule 5 already says so). Several BEAM nodes cannot share
  one file `[INFERENCE]`, and the file must not live on a network file system
  (WAL).
- A backup must use `VACUUM INTO` or the backup API, not a copy of the file
  while the app runs (not built).
- sqlite-vec is pre-1.0 and arrives as a prebuilt binary per platform. Setup,
  CI and the image build need the network once to fetch it. A new platform
  or version needs new checksum entries in `mix sqlite_vec.fetch`; Dependabot
  does not see it.
- Database tests no longer run in parallel. The suite still got faster
  (11.6 s to about 5 s on the owner's laptop), because it no longer waits for
  Postgres.
- If SQLite does not hold at scale, `Knowseek.Search` and
  `Documents.ingest/1` are still the only modules that touch the index, so
  another engine (LanceDB is the researched fallback) can replace it behind
  them.
