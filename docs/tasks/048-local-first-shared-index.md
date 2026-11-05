# 048. Local-first: nodes that share one search index

- Status: open
- Area: product design + `Knowseek.Documents`, storage engine, deployment
- Depends on: none

This is a design agenda, not an implementation task, and it is not an ADR.
It writes no code. The owner has made the decisions listed under "Decided by
the owner". Everything else is an open question with tradeoffs. No other
task's status changes because of this file.

## Goal

Explore what it would take to run Knowseek on the owner's own computers and
have those computers share one search index.

The owner's words: "run the service locally on your computer, and on your
other devices, and they share a search index."

## Decided by the owner

1. **Direction: local-first.** One user, or a few trusted people. No hosted
   public service.
2. **Hosting is not a goal now.** Free public hosting was judged a poor fit: the
   service has no authentication yet (task
   [009](009-users-and-api-keys.md) is parked), it needs an always-on host, and
   free database tiers are small.
3. **Scope cut: nodes are desktops and laptops, and maybe servers.** A server
   node is not essential. **Phones are out of scope.** The fallback for a
   phone is its browser, using the web UI of a node over a private network
   (topology A below). There is no phone app and no phone-side index.
4. **Constraint: a full node needs the whole stack.** Postgres with pgvector
   today, the Elixir release, and Ollama with `bge-m3`.

This is not yet an ADR, and the owner has not approved parking any other task.

## Context

### What the index holds

Facts below were read in the code on 2026-11-05 (origin/main `a0318f0`)
unless marked `[INFERENCE]`.

- `Knowseek.Documents.ingest/1` is the only write path into the index
  (architecture rule 2, `AGENTS.md`; `backend/lib/knowseek/documents.ex`). The
  only other writes in `backend/lib` are two deletes inside that module: the
  `Repo.delete!` of a stale alias in `dispatch/2`, and the `delete_all` of a
  document's chunks in `replace_chunks/2`. Its callers are
  `Knowseek.Discovery.run/2`, `POST /api/documents` (source forced to
  `"manual"`, `KnowseekWeb.DocumentController`) and `priv/repo/seeds.exs`.
- `ingest/1` is idempotent in the sense of ADR
  [0013](../decisions/0013-url-canonicalization-and-aliases.md): the URL is
  canonicalized (`Knowseek.Documents.URL`); a document is found by its URL, then
  by an alias, then (body of at least `min_alias_body_length/0`, 200 characters)
  by `content_hash`; otherwise it is new. An unchanged body is not re-chunked or
  re-embedded.
- A **document** (`Knowseek.Documents.Document`) holds `url` (unique, the
  identity), `title`, `body`, `source`, `content_hash`, `published_at`,
  `fetched_at`, `metadata`, `monthly_views` and `source_updated_at`. Its `id`
  is a random UUID made by each node, so ids cannot be shared. Aliases
  (`document_aliases`) are other URLs with the same body.
- **Derived data**, rebuilt from the documents: the `chunks` rows (the chunker
  `Knowseek.Documents.Chunker` splits `body`), `chunks.embedding`
  (`vector(1024)`, `bge-m3` by default, architecture rule 7), the generated
  `chunks.search_vector` (`to_tsvector('english', content)`) with its GIN
  index, and the HNSW index.
- `ingest/1` has no way to take a vector from the caller. It always calls
  `Knowseek.Embeddings.embed/2` for a new or changed body, outside the
  transaction (rule 5), and `Embeddings` rejects a wrong-size vector.
- Nothing records which model made a vector: there is no `embedding_model`
  column (ADR [0016](../decisions/0016-ollama-default-embeddings.md),
  "Nothing detects a model mismatch yet"). Vectors from different models are
  not comparable even at the same size (ADR
  [0004](../decisions/0004-embeddings.md)).
- **Caches are per node.** Entity resolution and the live-fact cards live in
  in-memory ETS caches that are disposable and restart empty (ADR
  [0017](../decisions/0017-live-fact-cards.md), `Knowseek.Cache`). They are not
  part of the index. Rate limits are per node too (`Knowseek.RateLimiter`;
  `docs/ARCHITECTURE.md`: "The limits are per node").
- **Discovery runs per node** (`Discovery.SeekWorker` on the Oban `discovery`
  queue) and decides what to fetch from the local index's coverage
  (`Knowseek.Search.Coverage`: a document counts as fresh when its
  `fetched_at` is within `max_age_seconds`).
- `monthly_views` (the ranking prior, ADR
  [0018](../decisions/0018-ranking-prior.md)) and `fetched_at` are values per
  document that each node sets when it ingests. Two nodes can hold different
  values for one URL.

### Sizes and costs

These come from the owner's session notes and from the unmerged branch
`origin/data-doc` (`docs/DATA-AND-JOBS.md`, measured 2026-11-01 on one M1
laptop, 43 Wikipedia articles, 993 chunks). **`docs/DATA-AND-JOBS.md` is not on
`main`**, so the figures are `[INFERENCE]` here: re-check them when it merges.

- A chunk is about **18 KB** all-in (table plus indexes). The HNSW index is
  about **8.9 KB** of that per chunk, the biggest single part (the branch says
  "half of the chunks table"; 8.9 of 18 is 49%, not more than half; the
  `docs/ARCHITECTURE.md` "Vector index health" section on `main` gives "about 8
  KB per live chunk, 313 MB for 40,000 chunks").
- The vector itself is 4,100 bytes. An article is 23.1 chunks and 21.9 KB of
  body on average in that sample, about 435 KB on disk.
- `[INFERENCE]`, arithmetic on those figures: the text of a document is about
  22 KB, so the derived data is about 95% of the disk. Sending only the
  documents is about 20 times smaller than the database; sending vectors too
  adds about 95 KB per document (23.1 chunks x 4.1 KB), so about 117 KB.
- Embedding on the receiving node: about 1.4 s per 20 chunks on the owner's M1
  with Ollama (about 70 ms per chunk, the owner's measurement). `[INFERENCE]`:
  1,000 documents (about 23,000 chunks) is about 27 minutes, one node at a
  time. The embedding is the throughput limit of any sync that recomputes.
- Postgres uses the HNSW index only above roughly **25,000 to 27,500**
  real-vector chunks (task [044](044-hnsw-recall-after-deletes.md), the
  planner experiment; `docs/ARCHITECTURE.md` "Vector index health"). Below it
  the vector query is already an exact scan. `[INFERENCE]`: at 23.1 chunks per
  article that is about 1,100 to 1,200 articles, and about 450 MB at 18 KB per
  chunk. A personal index may stay under that for a long time, which matters
  for the storage-engine question.

## Topologies

| | What it is | For | Against |
| --- | --- | --- | --- |
| **A. One host, thin clients** | One node runs the whole stack. Other devices open its web UI or call its API over a LAN or a private VPN. | Nothing to sync, one index, no new code for the index. The only way a phone can take part (scope cut). | The host must be on, and a laptop away from the network has no search. Not local-first for the thin devices. There is no authentication (task [009](009-users-and-api-keys.md) parked), so it must stay on a private network. The web UI is not served by the release yet (task [018](018-serve-frontend-in-production.md) parked; `docs/ARCHITECTURE.md` "Deployment"). Behind a proxy the rate limit needs `TRUSTED_PROXIES` (ADR [0023](../decisions/0023-rate-limiting-anonymous-endpoints.md)). |
| **B. Replicated full nodes** | Every node has the full stack and its own database. Nodes exchange documents and import them through `Documents.ingest/1`. | Each node works offline and fast. Reuses the one write path. The transport can be anything. A node that is lost loses nothing the others have. | Every node needs Postgres, the release and Ollama. Eventual consistency, so two nodes can briefly answer differently. Merge rules (question 4), embedding compatibility (question 3), schema skew (question 8). Each node pays the embedding time for imported documents unless it carries vectors. |
| **C. One shared network database** | Every node runs the Elixir release and Ollama, but all point `DATABASE_URL` (`backend/config/runtime.exs`) at one Postgres. | One real index, no merge logic. The `SeekWorker` uniqueness (one job per normalized query per hour, `unique` in `Discovery.SeekWorker`) lives in `oban_jobs`, so nodes would not repeat each other's discovery within the hour (`[INFERENCE]`: not tried). | It is topology A with extra steps: the database host must be reachable for any node to search, from a laptop on another network too. Postgres exposed beyond localhost needs TLS and real credentials (the runtime config has `ssl: true` commented out). Every search makes several round trips over the network. A laptop on a bad network is slow or down. Caches and rate limits stay per node. The embedding model must still be the same on all nodes, and nothing enforces it. |

A and B can be combined: B for the owner's own machines, A for the phone.

## Why replication fits this code base

`[INFERENCE]` for the design argument; the code facts above are verified.

- **A sync is an export of documents plus an import through
  `Documents.ingest/1`.** Rule 2 stays intact: no second write path, no direct
  insert of chunks. The URL is already the identity, so an export keyed by
  canonical URL needs no shared ids. The aliases of a document can travel as
  extra URLs of the same body: importing each URL with the same body is the
  path ADR 0013 already has (step 3 records the second URL as an alias).
- **Derived data is rebuilt locally.** Chunks, the text-search vector and the
  HNSW index are never exchanged by default. That keeps the export about 20
  times smaller than the database, independent of the storage engine, and
  independent of `Chunker` differences between versions.
- **File-based first.** The first export format is a folder of files (or one
  file), so any tool that moves files can be the transport: a folder-sync
  tool, a USB stick, `rsync`, a git repository. Peer discovery, pairing and
  trust (question 6) then are not blockers for the first version.
- **Warning: never sync a live database file with a folder-sync tool.** A
  Postgres data directory, or a SQLite file in use, copied by a tool that is
  not the database can arrive torn (half-written pages, a missing WAL), and
  two nodes writing the same file produce a corrupt one. Sync exported
  documents, not the engine's files. A closed, snapshotted SQLite file is a
  different matter and belongs to the storage-engine question.
- What does **not** fit yet, by the code: `ingest/1` takes no vector from the
  caller and `Documents` has no function to read documents for an export
  (`list_documents/1` returns no `body`). Both are new public functions of
  `Knowseek.Documents`, so rule 1 holds, but they are new code.

## Open questions

Each has a tradeoff and no decision. The checklist is the order to settle
them in.

- [ ] **1. Storage engine: stay on Postgres with pgvector, or move to SQLite?**
  - *Stay on Postgres.* Nothing changes. Cost: each node needs a Postgres
    server (Docker or a native install), a pgvector of at least 0.8 (checked
    at boot by `Knowseek.Search.PgvectorCheck`, ADR
    [0024](../decisions/0024-hnsw-iterative-scan.md)), and the per-node
    database. That is heavy for "run it on my laptop".
  - *Move to SQLite* (`sqlite-vec` for vectors, FTS5 for text, Oban's SQLite
    engine). Gains: one file and no server per node. Verified: Oban ships the
    engine, `Oban.Engines.Lite`, "An engine for running Oban with SQLite3"
    (`backend/deps/oban/lib/oban/engines/lite.ex`). What it would change in
    this repo:
    - **Search SQL.** `Knowseek.Search` uses `websearch_to_tsquery('english',
      ...)`, `ts_rank_cd`, the generated `search_vector` column, the pgvector
      `<=>` cosine distance, and per-transaction `set_config('hnsw.*')`
      (`backend/lib/knowseek/search.ex`). FTS5 ranking (`bm25`) is not
      `ts_rank_cd`, so full-text scores and the reciprocal-rank-fusion
      results change. `sqlite-vec` has no HNSW index in its stable release, so
      search is an exact scan; measured in the spike, which also measured the
      keyword and ranking differences.
    - **Migrations.** `backend/priv/repo/migrations/` uses
      `CREATE EXTENSION vector`, `vector` columns, a generated `tsvector`
      column, a GIN index and an HNSW index. All of them would be rewritten for
      the other engine, and `Knowseek.Repo` (`Ecto.Adapters.Postgres`) and
      `Knowseek.PostgrexTypes` change adapter.
    - **CI `migrations` job** (`scripts/check-migration-roundtrip`, the
      `pgvector/pgvector:pg17` service in `.github/workflows/ci.yml`) and the
      `backend` job's database service.
    - **Oban.** `engine: Oban.Engines.Basic` in `backend/config/config.exs`
      becomes `Lite`; `oban_jobs` is created by `Oban.Migration` for the other
      engine.
    - **Dockerfile and compose.** `docker-compose.yml` has the `db` service and
      `DATABASE_URL`; the release container would need the SQLite NIF
      (`exqlite`; not run on Linux by the spike), the arch-specific `vec0.so`
      from the sqlite-vec GitHub release assets (the hex package is frozen),
      checksummed in the `builder` stage of `backend/Dockerfile`, and no `db`
      service.
    - **Architecture rule 7** (`vector(1024)` fixed by the schema) would be
      restated for a `sqlite-vec` column of 1024 floats.
    - **The pgvector boot check and the HNSW guard of task 044**
      (`Knowseek.Search.PgvectorCheck`, `search_hnsw_test.exs`, ADR 0024) have
      no equivalent and would be removed, since there is no HNSW graph and no
      dead entries.
    - Concurrency: ingest transactions start with a write, which SQLite
      handled (5 concurrent ingests, 40 of 40 OK); a transaction that reads
      first failed 28 of 40 under the default mode unless
      `default_transaction_mode: :immediate` is set, and Oban's unique-job
      insertion is not atomic on SQLite (see "Spike results (SQLite)").
  - A throwaway **spike has run**; its measured results are in "Spike results
    (SQLite)" below. Its verdict is feasible with caveats, and a SQLite file
    cannot be shared over a network. What each answer would change for the
    topologies (no choice is made here):
    - *If Postgres stays:* topologies A, B and C all remain possible. C (one
      shared network database) is possible only on Postgres. A node needs
      Postgres, so B is the heaviest to run.
    - *If SQLite is chosen:* C is not possible. A works (the host has the
      file). B works with one file per node and documents exchanged through
      `ingest/1`, so the engine choice does not change the export format. A
      node is lighter (no server) and search is an exact scan, measured at
      about 35 to 173 ms for k=400 at 25,000 to 100,000 chunks. The
      keyword half is rewritten, ranking shifts slightly, and the cutover is
      the inventory in the spike results.
  - The export format does not depend on this choice: the export is
    documents, not engine files, so either engine can read it.
- [ ] **2. Unit of sharing and the export format.**
  - One document per record, keyed by canonical URL, with `url`, `title`,
    `body`, `source`, `published_at`, `fetched_at`, `metadata`,
    `monthly_views`, `source_updated_at`, and the alias URLs. Not the UUIDs,
    not `content_hash` (recomputed from `body` by `Document.ingest_changeset/2`;
    it could travel as a check).
  - Shape: JSON lines (one document per line, streamable, appendable) against
    one file per document (easy for folder-sync tools to merge, many small
    files) against a single archive. Compression: the text is the whole
    payload, so it compresses well (`[INFERENCE]`).
  - A format version field from the start (question 8).
  - Whole index each time, or only what changed since a point in time
    (`fetched_at`, or a per-node export cursor)? A full export is simpler and
    about 22 KB per article; incremental needs per-peer state.
  - New code: an export read in `Knowseek.Documents`, and an import that calls
    `ingest/1` per record.
- [ ] **3. Embeddings: recompute on the receiver, or carry them?**
  - *Recompute.* The receiving node embeds with its own configured adapter.
    Always correct, no compatibility check, the export stays small. Cost:
    about 1.4 s per 20 chunks on the M1 (above), and Ollama must be running on
    the receiver.
  - *Carry.* Add the vectors (about 95 KB per document, about four times the
    text) to the export and let the receiver skip
    embedding. Only safe if both nodes used the same model, and nothing records
    the model today. It needs the model label on each chunk
    (`chunks.embedding_model`), which task [017](017-re-embed-job.md) scopes
    ("Record the embedding model on each chunk") and which the owner's notes
    propose as a separate step, 017a (there is no such file in the repo yet).
    It also needs a new way to give `ingest/1` ready vectors, with the same
    dimension check as `Embeddings.embed/2`, and the receiver must reject a
    vector whose label differs from its configured model.
  - Suggested order, for the owner to confirm: recompute first; carry after
    017/017a, if the embedding time hurts.
- [ ] **4. Merge and conflict rules.**
  - What `ingest/1` does today when an import arrives (verified in code; the
    body replacement and the two `fetched_at` cases also by running
    `Documents.ingest/1` against this workspace's own scratch database on
    2026-11-05, hashing adapter, rows deleted afterwards):
    - **A changed body always wins**, whichever is newer: the body is replaced
      and the chunks are re-made. Importing an older export over a newer
      document would roll it back.
    - **`fetched_at` moves to now when the caller gives the value that is
      already stored** (`Document.put_default_fetched_at/1` uses `get_change`,
      and an unchanged field is no change). Observed: a document ingested with
      `fetched_at` 2026-01-01, ingested again with the same attrs, had
      `fetched_at` 2026-11-05. So re-importing the same documents would make
      old content look fresh to `Coverage`, and a sync loop would keep it
      "fresh" forever.
    - **A given `fetched_at` that differs is taken as is, even if older.**
      Observed: ingest with 2025-06-01 over a stored 2026-11-05 set it back to
      2025-06-01.
    - **A field left out keeps the stored value** (documented in
      `ingest/1`), so a missing `monthly_views` does not erase one.
    - **Which URL of two with one body is the document and which is the alias**
      depends on which node saw which first: `get_by_content_hash/1` takes the
      oldest by local `inserted_at`. `[INFERENCE]` (read, not run): two nodes
      can end with the same URL set but a different primary URL.
  - So a merge rule is needed, for example "import only if the incoming
    `fetched_at` (or `source_updated_at`) is newer than the stored one, and
    preserve the incoming `fetched_at`". The first rule needs a read before
    the write and a way to import without the `fetched_at` reset; both are
    design points for the import, not for the owner today.
  - Same URL fetched at different times: last-write-wins by `fetched_at`, or
    by `source_updated_at` when present? Equal bodies with different
    `fetched_at`: keep the newer.
  - **Deletions.** Check done: no delete path exists. The router has
    `index`, `show` and `create` for documents only
    (`KnowseekWeb.Router`), and the code deletes only the two cases above (a
    stale alias; a document's chunks on re-chunking). A document is removed
    only by hand in SQL, which cascades to chunks and aliases
    (`on_delete: :delete_all`). No feature deletes or expires documents (ADR
    0018 decided "no re-fetch for now"; the unmerged `docs/DATA-AND-JOBS.md`
    says "Nothing deletes them"). So tombstones are not
    needed for the first sync. But a hand deletion on one node would be
    undone by the next import from another node. If a delete feature is
    ever built, it needs a tombstone (URL plus time) in the export. Decide
    that when the feature is.
  - Aliases: union the alias URLs. A stale alias (its URL now serves another
    body) is removed locally by `ingest/1`; whether that propagates is part of
    the delete question.
- [ ] **5. Privacy and scope of documents.**
  - Today the index is public Wikipedia text plus the owner's seed notes
    (`source` is `wikipedia`, `seed`, `manual`). A manual document
    (`POST /api/documents`, source `manual`) may be private: a note, a pasted
    page.
  - Options: share everything between the owner's own nodes; share by
    `source` (for example never `manual`), by an explicit per-document flag
    (a new field and a schema change), or by a per-peer scope. With a few
    trusted people, a private manual document must not reach them by accident.
  - A file-based export puts plain text in a folder: where that folder lives
    (a cloud folder) is a privacy decision of its own.
- [ ] **6. Transport, peer discovery, pairing and trust.**
  - *Folder sync* (any tool). No network code. Trust is who can write the
    folder. Needs a conflict-free layout (one file per node's export, so two
    nodes never write one file).
  - *LAN or VPN, node to node.* Needs the API to export and import, peer
    addresses, and authentication between nodes; there is none today (task
    [009](009-users-and-api-keys.md) is parked and covers users and API keys,
    not nodes).
  - *Discovery of peers* (mDNS on a LAN, or a configured list) and *pairing*
    (a shared secret, a key pair). Not needed for the first file-based version.
  - Trust: imports go through `ingest/1`, which validates but does not judge
    content. A peer you trust can still poison the index (a wrong body, a huge
    one). The existing limit is a 1 MB request body (`docs/ARCHITECTURE.md`).
- [ ] **7. Duplicated discovery work, and caches that do not share.**
  - Each node's `SeekWorker` fetches from Wikipedia for a query that node's
    index does not cover. Two nodes asked the same thing both fetch it
    (topologies B and C differ here: C shares `oban_jobs`, B does not). Once a
    sync has run, the second node's index covers the query, so the duplicate
    shrinks with sync frequency.
  - An imported document counts for coverage with the `fetched_at` it
    carries (question 4): that decides whether the receiver re-fetches.
  - Entity and card caches are in memory and per node; they are cheap to
    refill (a Wikidata call, a card refresh) and need no sharing. Wikidata and
    ESPN rate limits are per source address, so several nodes on one home
    network share one budget (`[INFERENCE]`).
- [ ] **8. Schema and version skew between nodes.**
  - Nodes will not upgrade at the same time. The export needs a format version
    and a rule for an importer that sees a newer one (refuse, or ignore unknown
    fields).
  - Anything that changes what a stored vector means must be visible: the
    embedding model (question 3), the dimension (rule 7), and the `Chunker`
    (a different chunker makes different chunks from the same body, which is
    fine when the receiver chunks, and not when chunks travel).
  - The pgvector minimum (0.8) and the PostgreSQL version are per node.
- [ ] **9. What is a "server" node, and does it matter?**
  - Scope cut: not essential. If wanted: a node that is always on, so that
    laptops sync with it as a hub, and that serves the web UI to thin clients
    (topology A for phones). Nothing in the design should require one.
  - If it listens beyond localhost it needs the controls the code lacks
    (authentication, task 009; `TRUSTED_PROXIES`, ADR 0023). The license is
    AGPL-3.0-only (ADR [0019](../decisions/0019-license-agpl-3.md)); whether
    that obliges anything for a server shared with a few people is not
    examined here.
- [ ] **10. The ranking prior is per node.**
  - `monthly_views` is set at ingest, from the source at that time, and kept
    when a later ingest lacks it. Two nodes can hold different figures for one
    URL. Rankings then differ between nodes by the prior's bounded effect (at
    most a factor of 1.3, ADR 0018).
  - Options: ignore it (the difference is small and bounded); take the figure
    of the newer `fetched_at`; carry it in the export and let the merge rule
    of question 4 decide. Not a blocker.

## Spike results (SQLite)

These are **measured results from a throwaway spike** of question 1, run on
one M1 Pro laptop (macOS arm64, Elixir 1.20.4, OTP 28.5.0.6), in scratch
projects and scratch databases that were deleted afterwards. No repository
file was changed. Timings were taken at machine load 3 to 4; one
run at load 30 to 50 gave 109 ms where the quiet run gave 139 ms, so **treat
every number as plus or minus 2 times**. `[INFERENCE]` labels are the
spike's own. **No decision is recorded here.**

### Verdict

**Feasible with caveats. Not a drop-in way to share ONE index across
machines.** A SQLite file can be used from one host only: SQLite's own WAL
documentation says "WAL does not work over a network filesystem". That rules
out topology C (a shared network database) for SQLite, and a folder-sync tool
on the live file stays unsafe (see "Why replication fits this code base"). It
does **not** rule SQLite out for replicated nodes (topology B), where each
node has its own file and the nodes exchange documents. For one local node
it worked: sqlite-vec loads, exact search was fast enough up to about 100,000
chunks, and Oban has a SQLite engine.

### Versions and loading

exqlite 0.43.0 (bundles SQLite 3.54.1), ecto_sqlite3 0.26.0, ecto 3.14.3,
Oban 2.24.2. sqlite-vec is **v0.1.9** (stable, 2026-03-31) and
**v0.1.10-alpha.4** (a GitHub prerelease, 2026-05-18). The project is
pre-1.0, last pushed 2026-05-18, with 249 open issues; its licence is
Apache-2.0 or MIT. The hex package `sqlite_vec` is frozen at 0.1.0 (November
2024) and says it will not be published again, and upstream has no Elixir
bindings, so the extension has to come from the GitHub release assets: the
Dockerfile would fetch the architecture-specific `vec0.so`, checksummed, into
`priv`.

| Platform | Result |
| --- | --- |
| macOS arm64, raw exqlite | Worked (`enable_load_extension`, then `load_extension`; `vec_version()` returned `v0.1.9`). |
| macOS arm64, ecto_sqlite3 | Worked with `load_extensions: [".../vec0"]`. KNN returned correct rows on 0.1.9 and on alpha.4. |
| Linux arm64 and x86_64 (emulated), `debian:trixie-slim` (the release image's base) | Both `.so` builds load, run and need only libc. Tested with Debian's `sqlite3` CLI, **not exqlite**. |
| exqlite NIFs on Linux (gnu x86_64 and aarch64) | Precompiled artifacts exist and import `dlopen`/`dlsym`. Not run on Linux: `[INFERENCE]` that they load the extension (the Dockerfile builder also has `build-essential`). |

One thing failed: an Elixir binary passed through `Repo.query!` is bound as
TEXT, and vec0 rejects it ("JSON array parsing error"). Vectors need
`{:blob, bin}` or a custom Ecto type.

### Vector speed

1024-dimension float32, **random vectors** (iid Gaussian, normalised: latency
only, not recall on real text), 50 queries, median ms. "Tuned" is a 64 MB
cache plus 1 GB mmap; "default" is exqlite's 2 MB cache. sqlite-vec is an
exact scan: its time is linear in the chunk count, about 1.4 to 2.1 ms per
1,000 chunks on 0.1.9.

k=30:

| Chunks | sqlite-vec 0.1.9, default / tuned | sqlite-vec alpha.4, default / tuned | pgvector exact | pgvector HNSW (ef 100) |
| --- | --- | --- | --- | --- |
| 5,000 | 10.6 / 7.0 | 4.7 / 1.4 | 17.0 | 4.4 |
| 25,000 | 52.8 / 35.0 | 24.5 / 6.9 | 110.7 | 9.8 |
| 100,000 | 208.8 / 139.1 | 95.0 / 27.6 | 484.4 | 21.0 |

k=400 (what the app asks for: `limit` 10 times `candidate_factor` 40):

| Chunks | sqlite-vec 0.1.9, default / tuned | sqlite-vec alpha.4, default / tuned | pgvector exact | pgvector HNSW (ef 400, `strict_order`) |
| --- | --- | --- | --- | --- |
| 25,000 | 60.7 / 43.7 | 32.7 / 15.8 | 111.8 | 112.2 (the planner chose a sequential scan) |
| 100,000 | 240 / 173 | 128 / 62 | 455 | 94 |

- On random vectors the HNSW recall was 0.88, 0.55 and 0.32 at 5,000, 25,000
  and 100,000 chunks (k=30). Random data is the worst case for an
  approximate index and is not representative of real embeddings.
- Brute force has no dead entries, so the ADR
  [0024](../decisions/0024-hnsw-iterative-scan.md) problem does not exist on
  SQLite.
- `[INFERENCE]`: 1,000,000 chunks would take about 1.4 to 2.1 s per query.

Size and build cost:

| | 25,000 vectors | Build |
| --- | --- | --- |
| sqlite-vec `vec0` | 105.6 MB | 4.6 s insert, one transaction |
| pgvector | 344.6 MB (139.8 MB table, mostly TOAST, plus 204.8 MB HNSW) | HNSW build 58.6 s at 25,000, 246 s at 100,000 |

On the real corpus of the ranking replica (1,115 chunks, text, full-text
index and vectors): **SQLite file 10.3 MB** (`vec0` 8.4, text 1.3, FTS5 0.5)
against **Postgres 18.1 MB** (table 7.8, HNSW 9.1, GIN 1.1). `[INFERENCE]`:
scaled to 25,000 chunks, about 230 MB against 406 MB.

**Approximate indexes exist only in alpha builds.** Stable 0.1.9 has none
(`indexed by rescore|ivf|diskann` does not parse). The `v0.1.10-alpha`
prereleases (GitHub only) have `rescore` and DiskANN; IVF is compiled out.
Measured at 25,000 chunks on synthetic clustered vectors (real bge-m3
embeddings plus noise, so recall means something):

| Index | Median ms | Recall@30 | Cost |
| --- | --- | --- | --- |
| none (exact) | 24.3 | 1.0 | |
| rescore | 7.1 | 0.991 | file 119 MB |
| DiskANN | 5.8 | 0.971 | 57.7 s build, file 372 MB |

The alpha.2 release notes call DiskANN deletes "quite expensive", and the app
deletes and re-inserts all of a document's chunks on every re-ingest that
changes the body (`replace_chunks/2`).

### Ranking parity (a replica, not the app)

The replica uses the real `Chunker` and the real fusion, relevance and
group-by-document logic (RRF k=60, `min_similarity` 0.5) on both stores, and
omits the ranking prior and coverage. The corpus is 40 Wikipedia articles,
1,115 chunks, embedded with `bge-m3` through Ollama (1,127 texts in total).
The same code fuses each store's two lists, so any difference comes from the
keyword half.

| Check, 12 queries | Result |
| --- | --- |
| Vector lists (top 400) | Identical ids in 12 of 12; largest similarity difference 1.2e-6. |
| Keyword hit sets | The same chunk set in all 7 queries that had keyword hits. Queries with no keyword hit: 5 of 12 in both stores (AND semantics), so vector-only. |
| Keyword top-10 chunk overlap | 5 to 8 of 10, average 6.6. |
| Top-5 document sets | Identical in 11 of 12. |
| Top-5 order | Identical in 10 of 12. |
| Best chunk (the snippet) | Differs for 8 of 51 shared documents. |

The two differing queries were `new york knicks` (ranks 3 and 4 swapped) and
`futures promises` (a tie at the rank 19 to 20 boundary changes the last
hit). Where FTS5 differs from Postgres:

- **Ranking function.** `bm25` weights rare terms and normalises for length;
  `ts_rank_cd` does neither. On this corpus the document-level effect is
  small because the vector half dominates. `[INFERENCE]`: it would grow with
  a larger index and more keyword-driven queries (not tested).
- **Stop words.** FTS5 has none. "why is the sky blue" matched 1 chunk with
  the stop words kept, against 6 under Postgres's `english` list. A port
  needs a stop list.
- **Query syntax.** `what's new...` raised an FTS5 syntax error on the raw
  string. Every query needs tokenising and quoting, and the
  `websearch_to_tsquery` operators (`"phrase"`, `or`, `-`) need their own
  translation.
- **Tests.** `search_test.exs` asserts specific `ts_rank_cd` values and ties;
  those tests would be rewritten.

**Sample size: 12 queries, 40 documents.** It shows parity is plausible, not
proven.

### Jobs (Oban)

Oban 2.24.2 ships `Oban.Engines.Lite`. In a scratch ExUnit project, with the
real worker's options, these passed on it: `unique: [period: 3600, keys:
[:query], states: :incomplete]` (extra args ignored; completed or older jobs
do not conflict), `max_attempts: 3` with discard, a custom `backoff/1`, a
`timeout/1` that produced `Oban.TimeoutError` and a retry, `assert_enqueued`,
`refute_enqueued`, `perform_job`, and the Pruner plugin. A job ran about 11
ms after insert. (`Discovery.SeekWorker` defines no `timeout/1` on main.)

**Unique-job insertion is not atomic on the Lite engine.** 20 concurrent
identical inserts, 5 rounds:

| Setup | Jobs stored |
| --- | --- |
| Lite, plain | 19, 4, 4, 4, 3 |
| Postgres, Basic engine | exactly 1 every round |
| Lite, inside a `Repo.transaction` with `default_transaction_mode: :immediate` | exactly 1 every round |

`[INFERENCE]`: the PG notifier works only inside one VM, and the isolated
peer makes every node believe it leads, so several separate BEAM processes on
one file would fall back to polling.

### Cutover inventory

Counts from `git ls-files`.

| Area | Size | What is Postgres-specific |
| --- | --- | --- |
| `backend/lib` | 55 files, 5,852 lines; 14 files hit, about 7 need real change | `search.ex`: `websearch_to_tsquery`, `ts_rank_cd`, `<=>`, `set_config('hnsw.*')`, `'[0]'::vector`. `pgvector_check.ex` and `postgrex_types.ex`: deleted. `repo.ex`, `application.ex`: adapter and the check child. `documents.ex`: `Pgvector.new`, `on_conflict {:replace_all_except, ...}`, `returning`. `chunk.ex`: the vector field and the generated `search_vector`. UUID `binary_id` keys and the `:map` (jsonb) `metadata` need a decision. |
| Migrations and seeds | 9 migrations; 5 touch | `CREATE EXTENSION vector`, `vector(1024)`, generated `tsvector`, GIN, HNSW, `binary_id`, jsonb, the Oban Postgres migration. |
| `backend/config` | 4 of 5 files touch | Repo `types:`, `Oban.Engines.Basic`, the HNSW settings, `dimensions`, credentials, the test `enable_indexscan: "off"` and Sandbox, `DATABASE_URL`. |
| `backend/test` | 15 of 96 files touch (519 tests in 32 files) | `search_hnsw_test.exs` and `pgvector_check_test.exs` deleted or rewritten; `search_test.exs` (28 vector references); `release_test.exs`, `documents_test.exs`, the Ollama and Voyage tests, `data_case.ex`. |
| Dockerfile, `mix.exs`, `rel` | 4 files | Dependencies; the arch-specific `vec0.so` fetched with a checksum into `priv`; a volume for the file. |
| `docker-compose.yml`, `Makefile` | 67 and 126 lines | The `db` service goes; `DATABASE_URL` becomes a path; 18 Makefile lines (`db-up`, `db-reset`, drop). |
| `scripts/` | 3 to 4 of 9 files | `check-migration-roundtrip` assumes `ecto.create`/`ecto.drop` of a Postgres database. |
| `.github/` | 4 files | Two `services: db: pgvector/pgvector:pg17` blocks in `ci.yml` (the `backend` and `migrations` jobs); the `docker-compose` ecosystem in `dependabot.yml`. |
| Docs | 30 of 74 files mention Postgres, pgvector, HNSW or tsvector | 14 of them are ADRs, notably 0002, 0004, 0005, 0011, 0014, 0024, plus `ARCHITECTURE.md`, `AGENTS.md`, `README.md`. |

No advisory locks in `lib`, and no `LISTEN`/`NOTIFY` outside Oban's own use.

### Concurrency and operations

Test: an Oban Lite `discovery: 5` queue ingesting the 40 documents (about 28
chunks each) into a file preloaded with 25,000 vectors; WAL mode, pool of 10,
two readers running KNN (k=400) plus an FTS5 query. The ingest was a port of
`Documents.store` (upsert, delete old chunks, insert chunks and vectors, FTS5
kept in sync by triggers).

| Scenario | Result |
| --- | --- |
| 5 concurrent write-first transactions, no embed delay | 40 of 40 OK; wall 0.37 s; transaction median 13 ms, p95 52 ms, max 328 ms |
| Same, 300 ms embed delay outside the transaction | 40 of 40 OK; median 12 ms, p95 54 ms |
| Reads during writes | median 97 to 101 ms against 94 ms idle, no errors (WAL) |
| A transaction that reads before its first write, default (deferred) mode | **28 of 40 failed** ("Database busy"); the busy timeout does not help |
| The same with `default_transaction_mode: :immediate` | 40 of 40 OK |

The real `store/3` and `add_alias` transactions start with a write, so today
they are on the safe side. Other things that would bite:

- **WAL file.** It stayed at 106 MB after bulk loads without
  `journal_size_limit`.
- **Backup.** `VACUUM INTO` copied a 414 MB, 100,000-vector database in 1.0
  to 1.3 s and the copy passed `integrity_check` and served KNN. Copying only
  the main `.db` file while the WAL held 1,000 uncheckpointed rows produced a
  copy with none of them. A backup must be `VACUUM INTO` or the backup API.
- **Row ids.** `vec0` and FTS5 key on `rowid`, and SQLite's documentation
  says `VACUUM` may renumber rowids in a table without an explicit INTEGER
  PRIMARY KEY. The app's UUID chunk ids would need an integer key beside
  them.
- **Tests.** ecto_sqlite3 documents that async Sandbox tests are unsupported;
  14 of the 32 test files are `async: true`, 5 of them using the database.
- **Search time.** The exact scan is linear in chunk count and one query uses
  one core.

### What the spike could not verify

- exqlite itself running on Linux (only the NIF symbols were checked; the
  extension was tested through Debian's CLI).
- sqlite-vec speed on x86_64 and Linux.
- Ranking parity at scale, on real topical clusters, or with the ranking
  prior.
- Postgres under 5 concurrent ingests (compared by reasoning only).
- Any multi-node sharing: Litestream, LiteFS, rqlite, or any other layer that
  copies or replicates a SQLite file.
- ANN recall on real data beyond the 25,000-chunk synthetic-clustered test.

## Decisions needed from the owner

1. Is topology B (replicated full nodes) the direction to explore, with A for
   the phone, or is A or C enough?
2. Is a private manual document a real case? That decides question 5 before
   the first export exists.
3. Recompute embeddings on import first, and carry vectors only after
   017/017a? (Question 3.)
4. Is the first transport a folder of files, so that peer discovery and
   pairing wait? (Question 6.)
5. After the spike: is moving off Postgres wanted if it works, or is Postgres
   with pgvector the baseline for nodes? (Question 1.)
6. Does the import use "newer `fetched_at` wins", and may `Documents` get an
   import that preserves the given `fetched_at`? (Question 4.)

## Suggested first experiments

- **A. Export and import between two scratch databases through `ingest`.**
  Two databases made from the repo's migrations. Fill one through
  `Documents.ingest/1`, read the documents out (a throwaway read, not
  committed), and import them into the other through `Documents.ingest/1` with
  the hashing adapter, then with Ollama. Measure: bytes of the export against
  the database, the import time with real embeddings, whether `fetched_at`,
  aliases and `monthly_views` come out equal, and what a second import does
  (the `fetched_at` reset above). Settles questions 2, 3 (recompute side) and
  most of 4.
- **B. The storage-engine spike.** Done once, as a throwaway: see "Spike
  results (SQLite)". It answered loading, vector speed, size, a ranking
  parity replica, Oban's SQLite engine, the cutover inventory and
  concurrency, and lists what it could not check (Linux, x86_64, parity at
  scale, multi-node sharing). A second round would cover those gaps if the
  owner wants to keep SQLite open.

## Out of scope

- Phones: no phone app, no phone-side index. A phone uses a node's web UI
  over a private network (topology A).
- A hosted public service, and free or paid hosting for one.
- Accounts and API keys (task [009](009-users-and-api-keys.md)).
- End-to-end encrypted cloud sync, or any sync service that Knowseek runs.
- Changing the embedding model, the vector size, or the index type
  (tasks [017](017-re-embed-job.md) and ADR 0004 cover them).
- Any code. This file is a design agenda; implementation tasks come after the
  owner's decisions.
