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
      results change. `sqlite-vec` has no HNSW index, so it is an exact scan
      (`[INFERENCE]`: consistent with this index staying under the 25,000
      chunk mark of task 044, but it needs a spike).
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
      (`[INFERENCE]`: `exqlite`, built in the `builder` stage of
      `backend/Dockerfile`) and no `db` service.
    - **Architecture rule 7** (`vector(1024)` fixed by the schema) would be
      restated for a `sqlite-vec` column of 1024 floats.
    - **The pgvector boot check and the HNSW guard of task 044**
      (`Knowseek.Search.PgvectorCheck`, `search_hnsw_test.exs`, ADR 0024) have
      no equivalent and would be removed, since there is no HNSW graph and no
      dead entries.
    - Concurrency: ingest uses `on_conflict` upserts and transactions for
      concurrent writers (`Documents`); one SQLite writer at a time is a
      different tradeoff (`[INFERENCE]`, not tested).
  - A **feasibility spike is running**; its results will be added below.
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

**Pending.** A feasibility spike of question 1 (SQLite with `sqlite-vec`,
FTS5 and Oban's SQLite engine) is running. The parent will add its results
here: what worked, what it measured, and what it could not do. Nothing in this
section is a result yet.

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
- **B. The storage-engine spike.** SQLite with `sqlite-vec`, FTS5 and the
  Oban Lite engine: does hybrid search over the same documents return a
  comparable top 10, how much is a node's index in size and in search time at
  1,000 and at 25,000 chunks, and what does the code change cost. Results go
  into "Spike results" above.

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
