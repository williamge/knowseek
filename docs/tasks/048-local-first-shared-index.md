# 048. Local-first instances that share what they find

- Status: open
- Area: product design + `Knowseek.Documents`, storage engine, deployment
- Depends on: none

This is a design agenda, not an implementation task, and it is not an ADR.
It writes no code. The owner has made the decisions listed under "Owner
decisions (2026-11-05)" and "Earlier owner decisions (own devices)". The
two-layer split under "Proposed direction (not decided)" is a proposal, not a
decision. Everything else is an open question with tradeoffs. No other
task's status changes because of this file.

## Goal

Explore what it would take for people who each run their own Knowseek
instance to connect those instances and share the documents each has found.

The owner's words, 2026-11-05: "you run an instance and use it, then you can
connect it to other people's instances and you share the data you've each
found."

The earlier goal was narrower: "run the service locally on your computer, and
on your other devices, and they share a search index." That case remains: it
is the owner's own devices, and the material below written for it (sizes,
merge rules, the SQLite spike) still applies to it.

## Owner decisions (2026-11-05)

The goal changed from one person's devices sharing one index to
**federation**: instances that belong to different people exchange what each
has found. One person's own devices are the simplest case of it.

1. **Peers are people you know, paired explicitly.** For now an instance
   shares only with instances its owner has paired with on purpose. There is
   no open network of strangers. The owner also wants a later version where
   people are incentivized to share openly; it is not designed here (see
   "Later: open sharing with incentives").
2. **Full text or pointers is undecided.** Whether a shared record carries
   the document's text, or a pointer (URL plus content hash) that the receiver
   re-fetches and verifies, is open (question 11).
3. **Nothing is shared until the owner opts in.** An instance shares nothing
   by default. Sharing starts only after its owner turns it on.

## Proposed direction (not decided)

Proposed by the agent writing this file on 2026-11-05. **The owner has not
decided it.** `[INFERENCE]` throughout, except the code facts and the
measurement it cites.

Two layers:

- **Records**, what instances exchange. One record per document found:
  `url`, `title`, `body` or its hash, `source`, `published_at`, `fetched_at`,
  `source_updated_at`, and who found it. A record is immutable,
  content-addressed (its id is the hash of its bytes) and signed by the
  instance that made it. An instance's records form an append-only log. The
  log is not necessarily SQL: it can be files.
- **The local index**, what each instance searches. Chunks, embeddings, the
  full-text and vector indexes, and the ranking prior. It is derived data,
  built on each instance from the records it holds, through
  `Knowseek.Documents.ingest/1`, in any engine.

What follows from the split:

- **The storage engine matters only for the local index.** Records are a log
  that any engine, or plain files, can hold, and every instance rebuilds its
  own index from them. So the Postgres-or-SQLite choice (question 1) is no
  longer on the critical path for sharing: it decides how heavy one instance
  is, not what instances exchange.
- **`Documents.ingest/1` stays the one write path** (architecture rule 2).
  Applying a record is ingesting it. No second write path, no direct insert
  of chunks.
- **Embeddings are not shared; the receiver recomputes them.** A vector from
  another instance may come from another model (nothing records the model
  today, ADR [0016](../decisions/0016-ollama-default-embeddings.md)), and a
  receiver cannot inspect a vector for tampering the way it can read a text.
  Cost: about 1.4 s per 20 chunks on the owner's M1 Pro with Ollama (about 70
  ms per chunk; see "Sizes and costs"), so about 27 minutes for 1,000
  Wikipedia articles (`[INFERENCE]`, arithmetic).
- **Identity is a keypair per instance, and records are signed with it.**
  That replaces user accounts as the first security piece for sharing: a
  peer is known by its public key, not by a login. Task
  009 (parked; file removed, see git history) (users and API keys) is not changed by
  this file; it stays parked and still covers access to one instance's API.
- **Pull-based following of paired peers.** An instance fetches the logs of
  the peers its owner paired with (decision 1), from the point it last read.
  Nothing is pushed to an instance that did not ask.
- **Provenance per document.** Each document records who found it: this
  instance, or which peer (one or several). It feeds ranking (trust per peer,
  question 13) and the UI ("found by me", "found by Alice").
- **Retraction records instead of deletes.** A log is append-only, so a peer
  withdraws a record by publishing a retraction that names it. There is no
  delete path today (question 4, "Deletions"), so the receiving side of a
  retraction is new code (question 12).

## Earlier owner decisions (own devices)

These were made for the own-devices goal and still hold for that case.

1. **Direction: local-first.** One user, or a few trusted people. No hosted
   public service.
2. **Hosting is not a goal now.** Free public hosting was judged a poor fit: the
   service has no authentication yet (task
   009 (parked; file removed, see git history)), it needs an always-on host, and
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
  real-vector chunks (task 044 (done; file removed, see git history), the
  planner experiment; `docs/ARCHITECTURE.md` "Vector index health"). Below it
  the vector query is already an exact scan. `[INFERENCE]`: at 23.1 chunks per
  article that is about 1,100 to 1,200 articles, and about 450 MB at 18 KB per
  chunk. A personal index may stay under that for a long time, which matters
  for the storage-engine question.

## Topologies

### What the 2026-11-05 decisions change

These follow from the owner decisions above; the table below was written for
the own-devices case and is kept as it was.

- **C does not fit sharing between different people.** One database that
  every instance writes means one owner of the data, credentials handed to
  every peer, and no per-person opt-in (decision 3) or per-peer choice of what
  to accept. It remains a possible own-devices setup on Postgres only.
- **B is the model.** Each instance keeps its own index and exchanges records
  with the instances its owner paired with (decision 1), and applies them
  through `Documents.ingest/1`. In the proposed two layers, what B exchanges
  is records, not engine files.
- **A still covers your own phone.** A phone opens the web UI of its owner's
  instance over a private network; it is not a peer and holds no index.

### Own-devices topologies (earlier table)

| | What it is | For | Against |
| --- | --- | --- | --- |
| **A. One host, thin clients** | One node runs the whole stack. Other devices open its web UI or call its API over a LAN or a private VPN. | Nothing to sync, one index, no new code for the index. The only way a phone can take part (scope cut). | The host must be on, and a laptop away from the network has no search. Not local-first for the thin devices. There is no authentication (task 009, parked; file removed, see git history), so it must stay on a private network. The web UI is not served by the release yet (task 018, parked; file removed, see git history; `docs/ARCHITECTURE.md` "Deployment"). Behind a proxy the rate limit needs `TRUSTED_PROXIES` (ADR [0023](../decisions/0023-rate-limiting-anonymous-endpoints.md)). |
| **B. Replicated full nodes** | Every node has the full stack and its own database. Nodes exchange documents and import them through `Documents.ingest/1`. | Each node works offline and fast. Reuses the one write path. The transport can be anything. A node that is lost loses nothing the others have. | Every node needs Postgres, the release and Ollama. Eventual consistency, so two nodes can briefly answer differently. Merge rules (question 4), embedding compatibility (question 3), schema skew (question 8). Each node pays the embedding time for imported documents unless it carries vectors. |
| **C. One shared network database** | Every node runs the Elixir release and Ollama, but all point `DATABASE_URL` (`backend/config/runtime.exs`) at one Postgres. | One real index, no merge logic. The `SeekWorker` uniqueness (one job per normalized query per hour, `unique` in `Discovery.SeekWorker`) lives in `oban_jobs`, so nodes would not repeat each other's discovery within the hour (`[INFERENCE]`: not tried). | It is topology A with extra steps: the database host must be reachable for any node to search, from a laptop on another network too. Postgres exposed beyond localhost needs TLS and real credentials (the runtime config has `ssl: true` commented out). Every search makes several round trips over the network. A laptop on a bad network is slow or down. Caches and rate limits stay per node. The embedding model must still be the same on all nodes, and nothing enforces it. |

A and B can be combined: B between instances (your own machines and, after
pairing, other people's), A for your phone.

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

Each has a tradeoff and no decision. The numbers are labels that other
sections refer to, not an order. Questions 11 to 13 were added, and 2, 5, 6,
7 and 8 rewritten, on 2026-11-05 for sharing between people. Suggested order
now (`[INFERENCE]`): 11 and 2 (what a record is), 5 (what is shared), 6
(pairing), 12, then the rest. Question 1 is off the critical path if the
two-layer split is taken.

- [ ] **1. Storage engine: stay on Postgres with pgvector, or move to SQLite?**
  - *Since 2026-11-05:* under the proposed two layers this question is about
    the local index only. Records do not depend on the engine, so this can be
    settled after sharing works, on how heavy one instance should be.
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
- [ ] **2. The record format and log storage.**
  - *Contents.* One record per document found: `url` (canonical), `title`,
    `body` or its hash (question 11), `source`, `published_at`, `fetched_at`,
    `source_updated_at`, the alias URLs, and the public key of the instance
    that found it. Not the local UUIDs. `content_hash` is SHA-256 of the body,
    hex (`Document.hash_body/1`), so a record can carry it and the receiver can
    check it. `monthly_views` and `metadata`: carry them, or let each instance
    fetch its own prior (question 10)?
  - *Content addressing.* A record's id is the hash of its canonical bytes.
    Gains: an identical record from two peers is stored once, a reference to
    a record cannot be altered, and a retraction can name exactly one record.
    Cost: a canonical encoding is needed (key order, number and time formats),
    or two instances hash the same content differently.
  - *Signatures.* Each record, or each batch of the log, signed with the
    instance key (question 6). Per record: any record can be verified alone,
    after being copied by anyone. Per batch: fewer signatures, but a record
    taken out of its batch can no longer be verified.
  - *Ordering.* A per-instance sequence number, or each record naming the
    hash of the previous one (a hash chain, as in some feed systems; see
    "Prior art"). A chain makes a gap or a rewritten history visible; a
    sequence number is simpler and enough for "give me what is after N".
    Times are not an order: clocks differ between instances.
  - *Storage.* Files (one JSON lines file per instance log, or one file per
    record named by its hash, as git stores objects), or a table in the local
    database. Files are engine-free and can be moved by any tool, including a
    folder-sync tool (one log per instance, so two instances never write one
    file; see "Why replication fits this code base"). A table is easier to
    query and to back up with the index, but ties the log to the engine.
    Compression: the text is the whole payload, so it compresses well
    (`[INFERENCE]`).
  - *Versioning.* A format version in every record or log header from the
    start (question 8).
  - *Whole or incremental.* With an append-only log a peer pulls only what
    is after the last record it read; the state is one position per peer.
  - New code: writing records from this instance's ingests, and an import that
    verifies a record and calls `ingest/1`.
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
  - *Since 2026-11-05:* between different people the proposal is recompute
    only: a vector from someone else's instance cannot be checked against its
    text and may come from another model. Carrying vectors stays an option
    only between one owner's own devices.
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
    that when the feature is. *Since 2026-11-05:* sharing between people
    needs a way to withdraw a record, so this becomes question 12.
  - Aliases: union the alias URLs. A stale alias (its URL now serves another
    body) is removed locally by `ingest/1`; whether that propagates is part of
    question 12.
  - Between people, "newest wins" is also a trust question: a peer can claim
    any `fetched_at`. A record from a peer that would replace a body this
    instance fetched itself may need a different rule (question 13).
- [ ] **5. Privacy: what sharing reveals, and the opt-in granularity.**
  - Decided: nothing is shared until the owner opts in (decision 3). Open:
    what the opt-in covers.
  - **Shared records reveal interests.** Discovery is triggered by searches:
    `SeekWorker` fetches pages for a query the local index does not cover. So
    the documents an instance found, with their `fetched_at` times, are a
    trace of what its owner searched for and when, even when every page is
    public Wikipedia text. Coarser times in shared records (the day, not the
    second) would reveal less, but `fetched_at` also drives coverage
    (question 7). `[INFERENCE]`.
  - **Private documents.** A manual document (`POST /api/documents`, source
    `manual`) may be private: a note, a pasted page. It must never reach a
    peer by accident.
  - Granularity of the opt-in, each with a cost:
    - *Per document.* Precise; tedious for hundreds of documents found
      automatically, and needs a new field (a schema change).
    - *Per source or topic.* For example share `wikipedia`, never `manual`.
      Source is a field today; a topic is not, so topic scopes need a
      classification that does not exist.
    - *Per peer.* Different scopes for different people. More state, and the
      UI must make clear who sees what.
    - Combinations, and a default for documents found after opting in: shared
      automatically within the chosen scope, or held for review.
  - **Forwarding.** A signed record can be passed on by a peer to someone the
    finder never paired with, and still verify. Allow it (more coverage), or
    have peers share only what they found themselves (less leakage)? Nothing
    technical stops a peer from forwarding; it can only be a rule of the
    software.
  - A file-based log puts plain text in a folder: where that folder lives (a
    cloud folder) is a privacy decision of its own.
- [ ] **6. Pairing UX, key exchange and transport.**
  - *Identity.* One keypair per instance, made on first start or when the
    owner opts in (proposed direction). Which signature scheme is open;
    `[INFERENCE]`: Erlang's `:crypto` can sign and verify, so no new
    dependency is needed (not checked here).
  - *Key exchange*, each with a cost:
    - Copy a public key (or its fingerprint) and an address, both ways, by
      any channel the two people trust. Simple, no server; easy to get wrong
      and nothing checks the channel.
    - A short-lived invite code typed on the other instance, after which the
      instances swap keys over the network. Convenient; needs both online at
      once and an endpoint that accepts invites.
    - A QR code shown on one screen, scanned by the other. Strong in person;
      a desktop instance usually has no camera.
    - Trust on first use (accept the key seen first) is the easiest and the
      weakest against a man in the middle.
  - *Lost or rotated keys.* A lost key is a new identity: every peer pairs
    again. A compromised key is question 12.
  - *Transport.*
    - *Folder sync* (any tool). No network code. One log file per instance,
      so two instances never write one file. Trust in the transport is not
      needed when records are signed.
    - *LAN or VPN, instance to instance.* An endpoint that serves the log to
      paired keys only, and a client that pulls from it. Authentication by
      the instance key, not by user accounts (task
      009 (parked; file removed, see git history), unchanged, covers users and API keys
      of one instance).
    - *Over the internet between homes.* An instance behind a home router is
      usually not reachable (`[INFERENCE]`). A VPN both join, a shared
      folder, or a relay that stores signed logs it cannot alter; a relay is
      a service someone runs, which "no hosted service" (earlier decision 1)
      does not cover.
  - *Discovery of peers* (mDNS on a LAN, or a configured list). Only paired
    peers are pulled (decision 1), so discovery is a convenience, not a need.
  - Trust: imports go through `ingest/1`, which validates but does not judge
    content. A paired peer can still poison the index (a wrong body, a huge
    one, many records). The existing limit is a 1 MB request body
    (`docs/ARCHITECTURE.md`), which applies to HTTP requests, not to records
    read from a file. Limits per peer are part of question 13.
- [ ] **7. Duplicate discovery across peers, and caches that do not share.**
  - Each instance's `SeekWorker` fetches from Wikipedia for a query its own
    index does not cover. Two instances asked the same thing both fetch it
    (topologies B and C differ here: C shares `oban_jobs`, B does not).
  - *Passive.* Pull peers' logs on a schedule and ingest them; the duplicate
    shrinks with pull frequency. Reveals nothing beyond what was shared
    anyway, and needs no peer to be online at search time.
  - *Ask peers before Wikipedia.* Send the query to peers first. Saves
    fetches and rate-limit budget, but every query is revealed to every peer
    asked (a much stronger leak than records, question 5), adds latency, and
    needs peers online and a query endpoint beyond pulling.
  - An imported document counts for coverage with the `fetched_at` it
    carries (question 4): that decides whether the receiver re-fetches. A
    peer's old `fetched_at`, or a forged one, changes what this instance
    fetches.
  - Entity and card caches are in memory and per node; they are cheap to
    refill (a Wikidata call, a card refresh) and need no sharing. Wikidata and
    ESPN rate limits are per source address, so several nodes on one home
    network share one budget (`[INFERENCE]`).
- [ ] **8. Schema and version skew between instances.**
  - Instances will not upgrade at the same time, and between people they may
    never run the same version. Every record (or log header) needs a format
    version, and an importer needs a rule for a newer one: refuse it, or
    ignore unknown fields. The signature must cover the bytes as sent, so an
    importer that drops unknown fields must still verify the original.
  - The signature scheme and the hash of content addressing need versions
    too, so either can be replaced later.
  - The local index can change freely: it is rebuilt from records, so a new
    chunker or embedding model on one instance does not affect its peers.
  - Anything that changes what a stored vector means must be visible: the
    embedding model (question 3), the dimension (rule 7), and the `Chunker`
    (a different chunker makes different chunks from the same body, which is
    fine when the receiver chunks, and not when chunks travel).
  - The pgvector minimum (0.8) and the PostgreSQL version are per instance.
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
    of question 4 decide. Not a blocker. Between people, a figure in a
    record is a claim by the peer; the receiver can fetch its own instead.
- [ ] **11. Full text, pointers, or a hybrid.** (Undecided by the owner,
  decision 2.)
  - *Full text.* The record carries the body. The receiver gets exactly what
    the finder saw, works offline and when the source is gone, and verifies
    by the signature and `content_hash`. Costs: size (about 22 KB per
    article, above), and the finder redistributes the text. Wikipedia text is
    licensed CC BY-SA (general knowledge, not re-checked here):
    redistribution needs attribution and the same licence. The record has
    the URL and title; whether that is enough attribution is not examined.
    Manual documents may be anything, including text the owner may not pass
    on.
  - *Pointer* (URL plus content hash). The receiver re-fetches the URL and
    checks the hash. Small, and redistributes nothing. Costs:
    - Verification fails whenever the page changed since the finder fetched
      it; popular Wikipedia pages change often. What then: reject the record,
      or keep the fresh text as the receiver's own fetch (the record was only
      a hint)?
    - Even an unchanged page can hash differently: the body is the text
      after the source module's processing (`explaintext` extracts in the
      Wikipedia source), so two Knowseek versions may produce different text
      from one revision (`[INFERENCE]`).
    - Every receiver fetches from the source: network, the source's rate
      limits, and no offline use.
    - A manual document has no fetchable URL (its URL may be
      `urn:knowseek:sha256:...`, `Document.ingest_changeset/2`), so it cannot
      travel as a pointer.
  - *Hybrid.* Text for sources whose licence allows it and pointers for the
    rest; or a pointer plus a revision id, so the receiver fetches the same
    revision (Wikipedia pages have revision ids, general knowledge; the
    source asks only for the revision timestamp today, `rvprop: "timestamp"`,
    and `[INFERENCE]` the text-extract API may not serve old revisions); or a
    pointer by default with the text fetched from the peer on demand.
- [ ] **12. Revocation and retraction.**
  - *Retracting a record.* The finder appends a signed retraction naming the
    record's hash. A receiver should drop the document only if nothing else
    holds it (its own discovery, another peer), which needs provenance. A
    retraction is a request: a peer can ignore it, and copies already made
    stay.
  - *A delete path.* None exists today (question 4). Applying a retraction
    needs one in `Knowseek.Documents`; architecture rule 2 says only
    `ingest/1` writes documents and chunks, so a delete function may need an
    ADR first.
  - *Unpairing.* Stop pulling a peer. Keep what it shared, or drop
    everything only it provided (provenance again)?
  - *A compromised key.* Records signed with it after a point cannot be
    trusted. Times in records are claims of the signer, so the cut must be a
    position in the log (a sequence number or a chain hash), and peers that
    forwarded such records (question 5) have them too.
- [ ] **13. Trust per peer in ranking.**
  - *Equal.* A peer's documents rank like this instance's own. Simple; a
    careless or hostile peer's documents compete fully.
  - *A bounded weight per peer*, applied like the ranking prior (ADR
    [0018](../decisions/0018-ranking-prior.md), at most a factor of 1.3).
    Limits damage; a weight is hard to choose and to explain.
  - *Filter only.* Show or hide each peer's documents; provenance shown in
    the UI ("found by me", "found by Alice"). Clear; no gradation.
  - Limits per peer (records per pull, body size) bound flooding regardless
    of ranking.

### Later: open sharing with incentives

The owner wants a later version where people are incentivized to share
openly with instances they do not know. **Not designed here.** It raises:

- **What the incentive is.** Reciprocity (you get records if you give them),
  reputation (peers known for good records), or coverage (sharing makes your
  own search better). Each needs something to measure.
- **Sybil and spam resistance.** Keys are free, so one person can be many
  peers; an open network needs a cost or a web of trust before records count.
- **Poisoning and moderation.** Wrong, misleading or illegal content in
  records from strangers; who removes it, and how a retraction from a
  stranger is honoured.
- **Discovery of strangers' instances.** A directory, gossip between peers,
  or a relay; each is a service or a privacy cost.
- **Abuse of the opt-in default.** Pressure to share more than intended
  (rewards for sharing everything), and UI that makes the default look like
  consent.
- **Licensing at scale.** Redistributing full text to strangers multiplies
  question 11's licensing issue.

## Prior art

From general knowledge, **not re-verified for this file**. Each is listed for
one idea it may lend, not as a recommendation.

- **YaCy.** Peer-to-peer web search: each peer crawls and indexes, and peers
  share a distributed index so that a search reaches other peers. Open
  participation; known for uneven result quality and exposure to spam. The
  cautionary case for "Later: open sharing with incentives".
- **Secure Scuttlebutt.** Each identity is a keypair with an append-only
  feed of signed messages, each naming the previous one. Peers replicate the
  feeds of the identities they follow, so trust follows the follow graph.
  Closest to the proposed records log.
- **Nostr.** Events signed by a user's key, published to relays that store
  and serve them; clients follow public keys. Events are signed one by one,
  not chained; deletion is a request event that relays and clients may
  honour. Close to question 12's retraction.
- **git.** Content-addressed objects (named by their hash), fetched from
  remotes the user chooses. Only the objects not held yet are transferred.
  Close to pull-based following and to records named by hash.
- **ActivityPub.** Server-to-server federation: an actor's activities are
  pushed to the inboxes of its followers' servers; a `Follow` starts it, and
  a `Delete` may leave a `Tombstone` in place of the object. Push, where the
  proposed direction pulls.

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

1. ~~Is topology B (replicated full nodes) the direction to explore, with A
   for the phone, or is A or C enough?~~ Answered by the 2026-11-05 decisions:
   B between instances, A for the phone; C does not fit sharing between
   people.
2. Is a private manual document a real case? Opting in is decided (decision
   3); what remains is the granularity of the opt-in and whether peers may
   forward records (question 5).
3. Recompute embeddings on import first, and carry vectors only after
   017/017a, between own devices only? (Question 3.)
4. Is the first transport a folder of files, so that peer discovery waits?
   Which pairing method comes first? (Question 6.)
5. After the spike: is moving off Postgres wanted if it works, or is Postgres
   with pgvector the baseline for instances? (Question 1; off the critical
   path if the two-layer split is taken.)
6. Does the import use "newer `fetched_at` wins", and may `Documents` get an
   import that preserves the given `fetched_at`? (Question 4.)
7. Take, change or reject the two-layer split in "Proposed direction (not
   decided)".
8. Full text, pointers or a hybrid in records (question 11, decision 2).
9. Is a delete path for retractions wanted, given architecture rule 2?
   (Question 12; it may need an ADR.)
10. Do instances re-share only what they found themselves, or forward other
    instances' original signed records unchanged? (Question 5; experiment A
    showed that re-signing others' documents spreads `fetched_at` resets and
    erased fields.)
11. May full text against pointers be deferred? A record with an optional
    `body` field allows both (question 11; experiment A's results).

## Suggested first experiments

- **A. Export signed records from one instance and import them through
  `ingest` into another.** Two scratch databases made from the repo's
  migrations. Fill one through `Documents.ingest/1`, write its documents out
  as records signed with a throwaway instance key (a throwaway read, not
  committed), and import them into the other: verify each signature and
  `content_hash`, then call `Documents.ingest/1`, with the hashing adapter,
  then with Ollama. Measure: bytes of the records against the database, the
  import time with real embeddings, whether `fetched_at`, aliases and
  `monthly_views` come out equal, what a tampered record does, and what a
  second import does (the `fetched_at` reset above). Settles much of
  questions 2, 3 (recompute side) and 4.
  - Results: see "Results (spike, 2026-11-05)" below.
- **B. The storage-engine spike.** Done once, as a throwaway: see "Spike
  results (SQLite)". It answered loading, vector speed, size, a ranking
  parity replica, Oban's SQLite engine, the cutover inventory and
  concurrency, and lists what it could not check (Linux, x86_64, parity at
  scale, multi-node sharing). A second round would cover those gaps if the
  owner wants to keep SQLite open.

### Results (spike, 2026-11-05)

These are **measured results from a throwaway spike** of experiment A. Two
scratch databases stood in for two instances, A and B, on one M1 Pro laptop.
The hashing adapter was used throughout except one Ollama run, taken at a
load average of about 11, so **treat the Ollama timings as plus or minus 2
times**. 19 to 21 documents. Nothing was committed and no repository file was
changed. `[INFERENCE]` labels are the spike's own. **No decision is recorded
here.**

Setup: instance A held 14 Wikipedia articles fetched through the real
`Sources.Wikipedia`, 2 manual documents (one with a URL, one
`urn:knowseek:sha256:`), 1 alias (`?curid=974` with the Ada Lovelace body)
and 3 seed documents: 19 documents, 347 chunks. Records were canonical JSON
(sorted keys), `id` the SHA-256 of the record without `id` and `sig`, an
Ed25519 signature from OTP `:crypto`, and `origin` = `ed25519:<public key>`.
No record carried an embedding.

**Verdict.** One import through `ingest/1` copies everything today's attrs
carry: after the first import A and B were equal on every field and in chunk
counts. But a second pass flips `fetched_at` to now; an older record rolls
back a newer body; explicit nulls in a record erase stored values; and
echoing re-signed records back spreads both problems.

| Case | Observed | Implication |
| --- | --- | --- |
| First import | A and B equal on title, hash, `fetched_at`, `source_updated_at`, `published_at`, views, metadata, source, aliases, and chunk counts. | One import copies everything today's attrs carry. |
| (a) Same file again | Counts and chunk ids unchanged (19 of 19), but **`fetched_at` moved to the import time for 18 of 19** (the alias case kept it). Re-importing one record 4 times flip-flopped: record value, now, record value, now. | A stored value equal to the given one is "no change" and resets to now. The import must always apply `fetched_at` and never lower it. |
| (b) Older record after a newer one | Body rolled back, all 20 chunks rebuilt with new ids; `fetched_at`, `source_updated_at` and views went back too. | Needs "skip unless newer". |
| (c) Newer record, changed body | Body replaced, chunk ids new, given `fetched_at`, newer `source_updated_at` and views kept. | Correct when the record really is newer. |
| (d) Alias | B ends with A's canonical URL and alias. | Importing each alias URL after the main one works. |
| (d2) B had found the mirror URL first | Same URL set, main URL and alias swapped between A and B. | Harmless for search; only a deterministic rule would make them equal. |
| (e) Tampered and foreign records | Edited body: `id_mismatch`; hash and `id` recomputed: `bad_signature`; unpaired key: `unknown_origin`; unpaired key claiming A: `bad_signature`; wrong hash signed by A: `content_hash_mismatch`; untouched record passed. | Check in order: paired origin, `id`, signature, `content_hash` against `body`. `ingest/1` does none of these. |
| (f) B's own newer copy of a URL | A's copy, fetched 2 days earlier, overwrote B's title, body and `fetched_at`. | "Newer wins" also protects what an instance found itself. |
| (g) Record fields in `ingest/1` | `content_hash` recomputed, not checked; `origin`, `id`, `sig`, `v`, `aliases` dropped silently. **An explicit null erases** (views 2912 to nil, title to nil, metadata replaced by `%{}`); no `fetched_at` means now. | The import must drop null fields and check the hash itself. |
| Echo (B's export back into A) | 20 of 21 unchanged documents got a new `fetched_at`; the nulls of (g) spread into A (one document lost title, views and metadata). | Forward the original signed record unchanged, or share only what you found yourself. |
| Record ids across instances | 0 of 21 equal; 2 of 21 even ignoring `origin`, `id`, `sig` (the `fetched_at` resets). | A record id names one signed record; "same document" is (canonical URL, `content_hash`). |
| Pointer check | 6 pages re-fetched through the real source about 5 minutes later: 6 of 6 equal hashes, same revision and views. | Extraction is repeatable for an unchanged revision. Not tested after a real edit. |

Sizes and timings:

| | Value |
| --- | --- |
| Export, 19 records | 336,751 B; gzip 123,615 B (36.7%); 30 ms |
| Record size | min 671, median 8,377, mean 17,722 (17.7 KB), max 40,755 B; bodies are 96% of the file, the rest 521 to 965 B per record |
| Index data in A | about 6.25 MB (14.69 MB database minus 8.44 MB empty); chunks 5.76 MB (HNSW 2.72 MB, text search 600 KB), about 17 KB per chunk |
| Export against the database | 1/18.6 of the index data (1/51 gzipped); 1/44 of the whole database |
| Signature check | mean 0.74 ms per record (0.16 to 2.3 ms) |
| Import, hashing adapter | 19 documents, 347 chunks in 1.22 s: 64 ms per document, 3.5 ms per chunk |
| Import, Ollama `bge-m3` | 3 documents, 122 chunks: mean 117 ms per chunk, about 93 ms per chunk after the first document (plus or minus 2 times) |
| 1,000 documents re-embedded | about 36 to 45 minutes at 23 chunks per document `[INFERENCE]` |

**Proposed record format v1** (the spike's proposal, not decided):

```json
{"v":1,"url":"<canonical>","aliases":["…sorted"],"title":"…","body":"…",
 "content_hash":"<sha256 hex>","source":"wikipedia","published_at":"…","fetched_at":"…Z",
 "source_updated_at":"…Z","monthly_views":116376,"metadata":{"pageid":974},
 "origin":"ed25519:<pubkey b64url>","id":"<sha256 of canonical unsigned bytes>","sig":"<ed25519 b64url>"}
```

- Required: `v`, `url`, `content_hash`, `source`, `fetched_at`, `origin`,
  `id`, `sig`.
- Unknown values are omitted, never null.
- Canonical form: RFC 8785 (JCS) if another language must ever produce
  records; the spike's encoder is deterministic only for Jason.
- Never in a record: UUIDs, `inserted_at`, chunks, vectors. Optional: a
  sequence number per origin, for incremental sync.

**Proposed import rules** (the spike's proposal, not decided):

1. Reject the record unless all pass: a supported `v`, a paired `origin`,
   `id` equal to the hash of the canonical bytes, a valid signature, and
   `content_hash` equal to SHA-256 of `body`.
2. Skip a record whose `id` is already applied.
3. Find the local document by URL, then by alias; if none, ingest it.
4. Same `content_hash`: do not re-chunk; set `fetched_at` to the later of the
   two, never back.
5. Different `content_hash`: apply only if the record is strictly newer, by
   `source_updated_at` when both have one (the source's own clock), else by
   `fetched_at`. A tie keeps the local copy. This blocks (b) and (f).
6. Remove null fields before ingesting; `metadata` and the other fields are
   replaced only when the record wins.
7. Aliases: import each alias URL after the main one (union); accept a
   different main URL as in (d2).
8. Re-share only documents you found yourself, or forward the original signed
   record unchanged.
9. Never overwrite a local `manual` document (`[INFERENCE]`: a proposal, not
   tested).

**Changes `ingest/1` would need** (none made):

- Preserve a given `fetched_at`: `put_default_fetched_at` defaults only when
  the caller gives no value. This is also a latent bug today: re-ingesting
  an unchanged page with the same `fetched_at` resets it to now.
- A newer-wins option, or a new `Documents.import_record/1` that compares
  versions in `dispatch/2`, where `locate/1` has already read the row. The
  comparison must be atomic, for example a conditional
  `UPDATE … WHERE fetched_at < $1`.
- Never lower `fetched_at`, also on the alias and same-content paths
  (`touch/2`, `adopt_url/2`).
- Store provenance: an `origin` and record `id` per document, or a records
  log table. A schema change, so it needs an ADR.
- An export read in `Documents` that returns bodies and aliases
  (`list_documents/1` returns no body).
- Null stripping and the hash check can live in the importer, with no change
  to `ingest/1`.

**Full text against pointer** (question 11; not chosen):

- *Full text.* Records average 17.7 KB. Self-contained, work offline, and
  carry manual and `urn:` documents. The signature proves who sent the text,
  not that the URL serves it.
- *Pointer* (`url`, `content_hash`, dates; about 0.5 to 1 KB, about 25 times
  smaller). The receiver re-fetches with the same source code and
  `max_chars`; at Wikipedia's 1 request a second, 1,000 documents mean about
  17 minutes of fetching. Re-fetch hashes matched 6 of 6 about 5 minutes
  later; not tested after a real edit, where a hash check fails
  (`[INFERENCE]`) and the pointer becomes a "go fetch this" hint. It cannot
  carry manual or `urn:` documents. It proves the URL served the content,
  which matters for open sharing later, and shares less private text.
- A record with an optional `body` field allows both.

**Not tested:** concurrent imports; more than 21 documents; Ollama timing on
a quiet machine or on more than 3 documents; a cross-language canonical
form; search-result parity between A and B; a pointer check after a real
page edit; transport, deletions and tombstones, version skew, and
private-document filtering.

## Out of scope

- Phones: no phone app, no phone-side index. A phone uses a node's web UI
  over a private network (topology A).
- A hosted public service, and free or paid hosting for one.
- Accounts and API keys (task 009 (parked; file removed, see git history), not changed
  by this file).
- Designing open sharing with strangers and its incentives (listed under
  "Later: open sharing with incentives", not designed).
- End-to-end encrypted cloud sync, or any sync service that Knowseek runs.
- Changing the embedding model, the vector size, or the index type
  (tasks [017](017-re-embed-job.md) and ADR 0004 cover them).
- Any code. This file is a design agenda; implementation tasks come after the
  owner's decisions.
