# Storage benchmarks (issue #79)

The scripts behind [local-storage-and-sync.md](../local-storage-and-sync.md).
They are standalone Elixir scripts (`Mix.install`), not part of the app, and
nothing here runs in CI.

## What you need

- Elixir 1.17 or newer (run on 1.20.4, OTP 28).
- macOS arm64. The scripts download the sqlite-vec loadable build for macOS
  arm64 from its GitHub release and check its SHA-256. For another platform,
  add its asset and checksum to `@vec_builds` in `bench_helpers.exs`.
- Ollama on `localhost:11434` with `bge-m3` (`make ollama`), for step 1 only.
- The Postgres container from `docker compose` (`knowseek-db-1`), for step 4
  only.
- Free disk: about 1.3 GB for 100,000 chunks; about 4 GB for 1,000,000
  without the float32 stores, about 12 GB with them.

Data goes to `$BENCH_DIR` (default `/tmp/knowseek-bench`), never into git.
Results are JSON files in `$BENCH_DIR/results/`; each script also prints a
table.

## Steps

Run from the repository root.

```sh
# 1. Real vectors: ~5,000 Wikipedia chunks and 200 query titles, embedded with
#    bge-m3 (about 6 minutes of embedding at 1.4 s per 20 chunks).
elixir docs/notes/bench/real_vectors.exs

# 2. Recall of int8 and 1-bit vectors on the real vectors.
elixir docs/notes/bench/recall.exs

# 3. SQLite at 100,000 and 1,000,000 synthetic chunks: build, then query with
#    each sqlite-vec build.
elixir docs/notes/bench/scale.exs build 100000
elixir docs/notes/bench/scale.exs query 100000 0.1.9
elixir docs/notes/bench/scale.exs query 100000 0.1.10-alpha.4
elixir docs/notes/bench/scale.exs build 1000000
elixir docs/notes/bench/scale.exs query 1000000 0.1.9
elixir docs/notes/bench/scale.exs query 1000000 0.1.10-alpha.4

# 4. pgvector baseline at 100,000 chunks, in the throwaway database
#    knowseek_bench_storage, which the script drops at the end.
elixir docs/notes/bench/pgvector.exs
```

Step 1 reuses its files on a second run. The Wikipedia articles are random,
so a fresh `$BENCH_DIR` gives other texts and slightly other numbers.

## Guards

- `BENCH_MIN_FREE_PCT` (default 15): a step stops when macOS reports less
  free memory (`memory_pressure`).
- `BENCH_F32_MIN_FREE_GIB` (default 15): `scale.exs build` skips the float32
  stores when one would be over 2 GiB and the disk has less free space than
  this, or would keep less than 10 GiB free after the build.
- `scale.exs build` stops if the generator repeated a row.
- The pgvector script never changes server settings. For the HNSW build it
  sets, for its own session only, `maintenance_work_mem` to 1GB and
  `max_parallel_maintenance_workers` to 0 (a parallel build needs more shared
  memory than the container's 64 MB `/dev/shm`).

## Files

| File | What it does |
| --- | --- |
| `bench_helpers.exs` | sqlite-vec download, SQLite pragmas, timing, recall, memory and disk checks, the synthetic data generator |
| `real_vectors.exs` | Step 1 |
| `recall.exs` | Step 2 |
| `scale.exs` | Step 3 |
| `pgvector.exs` | Step 4 |
