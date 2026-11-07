# Local storage at scale, and sync between instances

Issue [#79](https://github.com/williamge/knowseek/issues/79). Research only.
Nothing here is decided. Measured on 2026-11-06 on the owner's M1 Pro (16 GB,
macOS arm64). The scripts and how to rerun them:
[bench/README.md](bench/README.md). This note builds on the earlier SQLite
spike in [local-first-sharing.md](local-first-sharing.md#spike-results-sqlite).

## Question

Running locally, how should Knowseek store its index so it can grow large,
and how would two instances exchange what one has and the other lacks?

## Answer

**Storage.** Use SQLite: sqlite-vec for vectors, FTS5 for text. Exact
(brute-force) vector search is fast enough up to about 100,000 chunks on
the stable sqlite-vec, and up to a few hundred thousand on the next release.
At 1,000,000 chunks the app's query is too slow without an approximate index.

- At 100,000 chunks, exact float32 search takes 20 ms (k=10) and 49 ms
  (k=400) on sqlite-vec 0.1.10-alpha.4. On the stable 0.1.9 it takes 105 ms
  and 133 ms. FTS5 takes 0.5 ms at the median.
- At 1,000,000 chunks, int8 search takes 149 ms (k=10) and 425 ms (k=400) on
  the alpha, and 1.0 to 1.3 s on 0.1.9. The app asks for k=400.
- Store vectors as **int8 with one fixed scale**. Recall@10 is 0.98 on real
  bge-m3 vectors. It is a quarter of the size of float32 and a little faster.
- **Do not use 1-bit vectors for bge-m3.** Alone they reach recall@10 0.50.
  With float32 rescoring of 8 times as many candidates they reach 0.905, and
  at k=400 they are slower than int8.
- At 100,000 chunks SQLite already matches today's Postgres on the app's
  query (k=400): exact search in 49 ms on the alpha, against 46 ms for a
  forced HNSW scan with recall 0.85. Left to itself, the Postgres planner
  does not pick HNSW there; it scans exactly, in 237 ms. SQLite's files are
  about a third of Postgres's size.
- Fallback if SQLite does not hold past 1,000,000 chunks: LanceDB (embedded,
  IVF and HNSW indexes, BM25 full-text). Not DuckDB: its vector index on disk
  is experimental. Tantivy covers text only.

**Sync.** Exchange documents, not databases. A record is one `share: full`
document: canonical URL, source revision, normalized text, a SHA-256 of that
text, and the extractor version. The sender signs a bundle of records with an
Ed25519 key. Start with signed files and a hash list; add range-based set
reconciliation (Negentropy) when peers connect directly, over iroh or
libp2p. Vectors travel only between instances with the same model and
quantization. Queries never travel.

## Numbers

All latencies are milliseconds, median (p95), on a warm cache. "k" is the
number of results asked for: 10 is what a user sees, 400 is what the app
asks for (`limit` 10 times `candidate_factor` 40). "Alpha" is sqlite-vec
v0.1.10-alpha.4; "0.1.9" is the stable release. MB in the tables is MiB
(1,048,576 bytes), as the scripts report it.

### Quality on real bge-m3 vectors

5,000 chunks from 1,353 random long English Wikipedia articles, 200 query
texts (article titles: 100 from the corpus, 100 not). Recall against exact
float32 search.

| Vectors | Recall@10 | Recall@400 |
| --- | --- | --- |
| float32 (exact) | 1.0 | 1.0 |
| int8, one fixed scale (127 / largest value) | 0.979 | 0.987 |
| int8, sqlite-vec's `'unit'` scale | 0.912 | 0.940 |
| 1-bit only | 0.500 | 0.600 |
| 1-bit, float32 rescore of 2× candidates | 0.660 | 0.815 |
| 1-bit, float32 rescore of 4× | 0.803 | 0.955 |
| 1-bit, float32 rescore of 8× | 0.905 | 0.998 |
| 1-bit, float32 rescore of 16× | 0.964 | (more than the corpus) |
| 1-bit, int8 rescore of 8× | 0.898 | 0.986 |
| 1-bit of the vector minus the corpus mean, float32 rescore of 8× | 0.808 | 0.995 |
| pgvector HNSW, ef_search 40 / 400 | 0.955 | 0.985 |

Recall@400 with 8× candidates means 3,200 of 5,000 chunks, so it says
little. Subtracting the corpus mean before taking sign bits made 1-bit worse
here (short title queries sit far from the chunk mean).

### 100,000 chunks (synthetic, clustered)

| Store | Disk MB | Insert s | 0.1.9 k=10 | 0.1.9 k=400 | Alpha k=10 | Alpha k=400 | Recall@10 | RAM MB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| float32 | 395 | 3.7 | 105 (109) | 133 (146) | 20 (21) | 49 (59) | 1.0 | 340 to 375 |
| int8 | 100 | 1.5 | 100 (100) | 128 (149) | 16 (19) | 44 (47) | 0.97 | 25 to 100 |
| 1-bit only | 15 | 1.2 | 1.7 (2.0) | 31 (31) | 1.6 (1.8) | 31 (31) | 0.43 | 15 |
| 1-bit + float32 rescore 8× | 15 + 440 | 1.2 + 1.8 | 18 (22) | 97 (159) | 17 (23) | 97 (151) | 0.82 | 440 |
| 1-bit + int8 rescore 8× | 15 + 131 | 1.2 + 0.9 | 11 (17) | 89 (99) | 11 (16) | 87 (90) | 0.81 | 145 |
| FTS5 (text 108 + index 47) | 154 | 4.6 | 0.5 (6.0) | 0.5 (6.0) | 0.5 (6.3) | 0.5 (6.3) | | 160 |

Recall@10 here is against exact float32 on the same synthetic rows; the
real-vector table above is the one to trust for quality. "RAM" is how much
the process's resident memory grew during the queries; it is mostly the
mapped database file (see "Caveats"). FTS5 found matches for 89 of 100
queries.

### 1,000,000 chunks (synthetic, clustered)

| Store | Disk MB | Insert s | 0.1.9 k=10 | 0.1.9 k=400 | Alpha k=10 | Alpha k=400 | RAM MB |
| --- | --- | --- | --- | --- | --- | --- | --- |
| float32 | about 3,900 | skipped | about 1,050 | about 1,330 | about 200 | about 490 | about 3,900 |
| int8 | 1,001 | 16.0 | 998 (1,020) | 1,274 (1,307) | 149 (153) | 425 (448) | 910 to 970 |
| 1-bit only | 145 | 13.2 | 16 (17) | 301 (323) | 14 (15) | 301 (308) | 140 |
| 1-bit + int8 rescore 8× | 145 + 1,305 | 13.2 + 10.8 | 75 (80) | 913 (1,003) | 73 (78) | 908 (1,003) | 900 to 950 |
| FTS5 (text 1,075 + index 453) | 1,527 | 57.1 | 2.8 (57) | 2.9 (58) | 2.7 (59) | 2.8 (56) | 1,070 to 1,100 |

The float32 row is **not measured**: it is 10 times the 100,000 row. The
measured int8 numbers grew 9.5 to 10 times from 100,000 to 1,000,000, so the
scan is linear. Why it was skipped: see "Caveats". There is no recall at
this size, because recall needs the float32 table. FTS5 found matches for
95 of 100 queries.

### Today's Postgres at 100,000 chunks (baseline)

PostgreSQL 17.11, pgvector 0.8.7, in the shared `knowseek-db-1` container. A
table shaped like `chunks`: `vector(1024)`, a generated english `tsvector`
with GIN, HNSW with the app's defaults (m 16, ef_construction 64). Same
synthetic rows and queries as SQLite.

| | Result |
| --- | --- |
| Disk | 1,519 MB: table with TOAST 691, HNSW 781, GIN 45 |
| Load | 33.9 s insert (GIN in place), then 67.2 s HNSW build (one worker, 1 GB `maintenance_work_mem`) |
| Vector, k=10, ef_search 40 | HNSW 12 (82), recall@10 0.58 |
| Vector, k=400, ef_search 400, iterative scan `strict_order` | HNSW 46 (114), recall@400 0.85 |
| Vector, exact scan | 230 (272) at k=10, 237 (271) at k=400 |
| Planner choice with the app's settings | HNSW at k=10; **the exact scan at k=400** |
| Full text, `websearch_to_tsquery` + `ts_rank_cd` | 3.3 (25) at k=10, 2.2 (22) at k=400; matches for 86 of 100 queries |

The timed HNSW runs forced the index (`enable_seqscan = off`). On the real
5,000 vectors HNSW reached recall@10 0.955. The synthetic rows are hard for
HNSW (see "Caveats"), so 0.58 is a lower bound.

### Size per chunk

| | Bytes per chunk |
| --- | --- |
| sqlite-vec float32 | about 4,100 |
| sqlite-vec int8 | about 1,050 |
| sqlite-vec 1-bit | about 150 |
| FTS5 (text 1,130 + index 490, chunks of about 900 characters) | about 1,620 |
| Postgres today (table, HNSW, GIN) | about 15,900 |

## Method

- **Toolchain.** Standalone Elixir scripts (`Mix.install`) with what the app
  would use: Elixir 1.20.4, OTP 28, exqlite 0.43.0 (SQLite 3.54.1),
  sqlite-vec loadable builds v0.1.9 and v0.1.10-alpha.4 from the GitHub
  releases (SHA-256 checked), Postgrex 0.22.4 and pgvector 0.4.2 (Elixir).
  The hex package `sqlite_vec` stops at sqlite-vec 0.1.6, so it was not used.
- **SQLite settings.** WAL, `synchronous = NORMAL`, 64 MB page cache, 1 GB
  mmap. One file per store, so each size is its own. Rows went in 5,000 per
  transaction.
- **Real vectors.** 5,000 chunks of random long Wikipedia articles (12,000
  bytes of wikitext or more, at most 12 chunks each), chunked like
  `Knowseek.Documents.Chunker` (1,200 characters), embedded with bge-m3
  through Ollama 0.40.13. Wikipedia was called with at most 3 requests at a
  time and the project's User-Agent; it answered some requests with 429, and
  the client waited and retried.
- **Synthetic vectors.** Each row is one of the 5,000 real vectors plus
  Gaussian noise (sigma 0.02 per dimension, about 0.84 cosine to its base),
  normalized. Text is random sentences from the real chunks, about 1,000
  characters. The build checks that no row repeats.
- **Queries.** 50 of the real query vectors for vector search, 100 query
  texts for full text, after warm-up runs. FTS5 queries quote every word and
  AND them, like `websearch_to_tsquery`, ranked by `bm25`.
- **1-bit with rescoring.** The bit table returns k × 8 candidates by Hamming
  distance; a plain table (`id`, `blob`) re-ranks them by cosine. The
  alpha's built-in `rescore` index was not measured here (the earlier spike
  did, at 25,000 chunks).
- **Memory guard.** Each step stopped if macOS reported under 15% free
  memory. Free memory stayed between 40% and 60%. Ollama with bge-m3 stayed
  loaded throughout.

## Caveats

- **1,000,000 float32 was skipped.** The disk had 14.2 GiB free at the
  start, under the 15 GiB guard. The float32 vec0 table plus a float32
  rescoring table need about 7.6 GiB, which would have left under 10 GiB.
  A float32 scan at that size would also keep about 3.9 GB of the file in
  the page cache on a machine that already swaps.
- **Swap.** No swap-outs during any load. The query runs at 1,000,000 chunks
  swapped out about 1.4 GB in total (90,000 pages of 16 KB), with 40% memory
  free before. That is light, not heavy, but it shows 1,000,000 chunks is
  near what this machine holds alongside its usual load.
- **RAM is mostly page cache.** An exact scan reads every vector on every
  query. The process's resident memory grows by about the size of the vector
  table, because the file is mapped. The OS can drop those pages, but then
  the next query reads them from disk. So the real RAM need for fast search
  is the vector table's size: 100 MB per 100,000 chunks with int8.
- **Synthetic data is harder than real data.** Each real vector has about 20
  (100,000 rows) or 200 (1,000,000 rows) noisy copies at nearly the same
  distance from a query. That hurts approximate methods: 1-bit recall@10 was
  0.43 here against 0.50 on real vectors, and HNSW 0.58 against 0.955. Exact
  search latency does not depend on the data.
- **Real recall is from 5,000 chunks.** Quantization loses more recall as
  the index grows, because more neighbors crowd near each query. Recall at
  1,000,000 real chunks is not measured.
- **One machine, warm cache, one query at a time.** The earlier spike saw
  timings move by up to 2 times with machine load. The Postgres numbers
  include the round trip into the Docker VM, and their p95 is noisy. Cold
  cache was not measured (`purge` needs root).
- **k=400 is expensive in sqlite-vec.** Going from k=10 to k=400 adds 28 ms
  at 100,000 chunks and 276 ms at 1,000,000 (alpha, int8). For 1-bit it is
  most of the cost. The top-k step seems to grow with k times the row count
  `[INFERENCE]`.
- **The alpha is a GitHub prerelease.** It is 3 to 7 times faster on
  float32 and int8 scans than 0.1.9 here. Its release notes call DiskANN
  deletes "quite expensive".

## Fallbacks (desk research)

- **sqlite-vec.** Stable v0.1.9 (2026-03-31) has only exact search. The
  v0.1.10 alphas (latest alpha.4, 2026-05-18) add a `rescore` index, an IVF
  index compiled out by default, and DiskANN
  ([#276](https://github.com/asg017/sqlite-vec/pull/276),
  [#277](https://github.com/asg017/sqlite-vec/pull/277),
  [#278](https://github.com/asg017/sqlite-vec/pull/278),
  [releases](https://github.com/asg017/sqlite-vec/releases)). The ANN
  tracking issue [#25](https://github.com/asg017/sqlite-vec/issues/25) is
  still open. There are no upstream Elixir bindings; loading the release's
  extension into exqlite works.
- **LanceDB.** Embedded, Rust core, Apache-2.0, v0.41.0 (2026-10-29). Vector
  indexes IVF (flat, PQ, SQ, RaBitQ) and IVF_HNSW, plus a BM25 full-text
  index ([indexing docs](https://docs.lancedb.com/indexing),
  [releases](https://github.com/lancedb/lancedb/releases)). Official SDKs are
  Python, TypeScript and Rust. For Elixir there is only a community Rustler
  NIF, [`lancedb_ex`](https://hex.pm/packages/lancedb_ex) 0.5.1. It is the
  strongest fallback, at the cost of a NIF and a second store beside SQLite
  for everything that is not search.
- **Tantivy.** A Rust full-text library like Lucene, BM25, MIT, v0.26.1
  (2026-05-10), no vector index
  ([repo](https://github.com/quickwit-oss/tantivy),
  [releases](https://github.com/quickwit-oss/tantivy/releases)). Elixir only
  through community NIFs such as
  [`tantivy_ex`](https://hex.pm/packages/tantivy_ex). FTS5 is already fast
  enough (2.8 ms median at 1,000,000 chunks), so it brings nothing now.
- **DuckDB.** v2.0.0 (2026-10-21,
  [releases](https://github.com/duckdb/duckdb/releases)). The `vss` HNSW
  index persists on disk only behind `hnsw_enable_experimental_persistence`,
  because WAL recovery for it "is not yet properly implemented" and a crash
  can lose or corrupt data; deletes only mark entries until a compaction
  ([vss docs](https://duckdb.org/docs/2.0/core_extensions/vss.html)). The
  `fts` index does not follow table changes unless created with
  `incremental = 1`
  ([fts docs](https://duckdb.org/docs/2.0/core_extensions/full_text_search.html)).
  An analytics engine with an experimental vector index is a poor fit for
  an index that is written on every ingest.

## Sync sketch

The model from the issue, made concrete. `[INFERENCE]` throughout: none of it
is built or measured.

**What travels: records, not the database.** The source text and its
metadata are the truth; chunks, vectors and the full-text index are derived
data that each instance rebuilds through `Documents.ingest/1` (architecture
rule 2). That also makes a model switch a re-embed, not a migration. A record
is one document:

| Field | Purpose |
| --- | --- |
| `url` (canonical), `source_revision` | Identity. The revision is the source's own (a Wikipedia revision id, an ETag), else the fetch time. |
| `text` | Normalized extracted text. |
| `text_sha256`, `extractor` (name and version) | Integrity. Two instances that extract the same revision with the same extractor version get the same hash. A new extractor version gives a new hash for the same identity. |
| `title`, `source`, `license`, `attribution`, `modified`, `share`, `fetched_at` | As stored today ([ADR 0026](../decisions/0026-per-document-license-fields.md)). |

- **Only `share: full` documents travel.** `pointer` sends the identity and
  the hash, and the receiver fetches the text itself. `none` never leaves.
  Queries, search history and anything from local usage never travel.
- **Signed bundles.** Each instance has an Ed25519 key pair. A bundle is a
  manifest (sender's public key, time, record hashes, optional vector block)
  plus the records; the sender signs the manifest's SHA-256. Erlang's
  `:crypto` does Ed25519 and SHA-256 with no new dependency
  ([crypto docs](https://www.erlang.org/doc/apps/crypto/crypto.html),
  [RFC 8032](https://www.rfc-editor.org/rfc/rfc8032)).
- **Receiving.** Check the signature, then each record's text hash, then
  ingest it as received from that peer. Received text ranks below your own
  until a re-fetch of the URL gives the same hash (same extractor version).
- **Vectors travel only between equal models.** The vector block names the
  model (name and digest, here `bge-m3` `79076464…`), the dimensions, the
  chunker version and the quantization (int8 and its scale). A receiver with
  anything different drops the block and re-embeds: about 70 ms per chunk on
  this machine, so 1,000 articles of 4 chunks take about 5 minutes. int8
  vectors add about 1 KB per chunk to a bundle, about as much as the text.

**What you have that I lack.** Three options, simplest first:

1. **Hash lists.** Exchange the sorted list of record hashes, then send the
   difference. 32 bytes per document: 3.2 MB for 100,000 documents. Fine for
   file bundles and for small peers.
2. **Range-based set reconciliation** (RBSR, [Meyer,
   arXiv:2212.13567](https://arxiv.org/abs/2212.13567)). Peers compare
   fingerprints of sorted ranges and split only the ranges that differ.
   Traffic grows with the number of differences (times a log factor) and it
   needs log(n) round trips and no state per peer.
   [Negentropy](https://github.com/hoytech/negentropy) implements it (C++,
   JS; ports in Rust and Go) and Nostr uses it
   ([NIP-77](https://github.com/nostr-protocol/nips/blob/master/77.md));
   iroh-docs syncs with RBSR too. No Elixir library exists; the algorithm is
   small enough to write.
3. **IBLT** ([Goodrich and Mitzenmacher,
   arXiv:1101.2245](https://arxiv.org/abs/1101.2245); [Eppstein et al.,
   SIGCOMM 2011](https://doi.org/10.1145/2018436.2018462)). One message after
   estimating the size of the difference, but decoding fails and must be
   retried when the estimate is too low.

RBSR suits peers that talk often and differ a little; hash lists suit files.

**Transport.** File bundles first (a folder, a USB stick, a download link):
no networking, and the bundle format is the same one the network will carry.
Peer-to-peer later:

- [iroh](https://github.com/n0-computer/iroh) v1.4.1 (2026-10-22): QUIC
  connections dialed by public key, with hole punching and relay fallback.
  iroh-blobs (BLAKE3 verified streaming) and iroh-docs (RBSR) are still 0.x.
  Rust only; Elixir would need a Rustler NIF or a sidecar process.
- [libp2p](https://libp2p.io): QUIC or TCP with Noise and Yamux, relays,
  hole punching (DCUtR), Kademlia. rust-libp2p v0.57.1 and go-libp2p v0.51.0;
  a third-party pure-Elixir [`libp2p_elixir`](https://hex.pm/packages/libp2p_elixir)
  exists.

iroh's key-based dialing matches "peers are people you pair with on purpose"
(an Ed25519 key per instance) more directly than libp2p's DHT.

## Input for #80

- **SQLite holds today's size easily.** The dev index has 303 chunks. With
  sqlite-vec 0.1.9 an exact search takes about 133 ms at 100,000 chunks for
  the app's k=400, plus under 10 ms for FTS5. That answers #80's open
  question: exact search is fine to about 100,000 chunks on 0.1.9.
- **Pin sqlite-vec v0.1.9**, the loadable extension from the GitHub release
  with its SHA-256, not the hex package. Move to 0.1.10 when it is stable: it
  is 3 to 7 times faster on the same scan.
- **Keep float32 in #80.** It matches today's `vector(1024)`, and the
  similarity threshold (`min_similarity` 0.5) and the search tests stay
  exact. int8 is a later step for size, not for #80.
- **Give every chunk an integer key** for `vec0` and FTS5 (the spike found
  rowids can move on `VACUUM` otherwise).
- **k=400 costs.** In sqlite-vec the k=400 query costs 2.4 to 2.9 times the
  k=10 query (alpha). Lowering `candidate_factor` is a cheap lever later; it
  changes ranking, so it is not for #80.
- **Size.** A SQLite index (float32 vectors, text and FTS5) is about 5.8 KB
  per chunk against 16 KB in Postgres today.
- **Rebuilding is cheap; re-embedding is not.** Loading 100,000 chunks into
  float32 vec0 and FTS5 took 8 s. Embedding them takes about 2 hours on this
  machine (70 ms per chunk).

## Proposed follow-up issues

Not opened. Each would go through the plan gate.

1. **Index as derived data.** Store normalized text, its SHA-256 and the
   extractor version on each document, and add a rebuild command that
   re-chunks and re-embeds from stored text. Prerequisite for sync and for a
   cheap model switch.
2. **Record the embedding model per vector set** (name, digest, dimensions,
   quantization). Prerequisite for vectors in bundles and for a safe re-embed.
3. **int8 vectors** once the index passes about 100,000 chunks: one fixed
   scale, measured recall@10 0.98.
4. **Approximate search at 1,000,000 chunks.** Measure sqlite-vec DiskANN and
   the `rescore` index on real vectors when 0.1.10 is stable, with deletes
   (re-ingest deletes and re-inserts a document's chunks). Compare with
   LanceDB if they fall short.
5. **Tune `candidate_factor`** against ranking quality, since the k=400
   candidate list drives brute-force cost.
6. **Sync v1: signed file bundles.** Export and import `share: full` records
   with an Ed25519 instance key and a hash list; received text ranked below
   own until a re-fetch check.
7. **Sync v2: direct peer sync.** RBSR over record hashes on a peer-to-peer
   transport (iroh first). After v1 and #58's pairing design.
