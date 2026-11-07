# Step 4: today's stack as the baseline, at 100,000 chunks only.
#
# Creates the throwaway database knowseek_bench_storage in the shared
# knowseek-db-1 container, loads the same synthetic rows as scale.exs (same
# generator, same seeds) into a table shaped like `chunks` (vector(1024), a
# generated english tsvector with GIN, HNSW with the app's defaults), and
# measures insert and index build time, sizes, latency and recall. Then it
# loads the real bge-m3 vectors into a second table for recall on real data.
# The database is dropped at the end, also when a step fails.
#
# Server settings are never changed. For the HNSW build, this session only
# (SET) raises maintenance_work_mem to 1GB and turns parallel workers off: a
# parallel build puts the graph in shared memory, and the container's
# /dev/shm is 64 MB.
#
# Run: elixir docs/notes/bench/pgvector.exs   (PGHOST, PGPORT, PGUSER, PGPASSWORD)
Mix.install([
  {:exqlite, "~> 0.43"},
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"},
  {:postgrex, "~> 0.20"},
  {:pgvector, "~> 0.3"}
])

Code.require_file("bench_helpers.exs", __DIR__)
Postgrex.Types.define(BenchTypes, Pgvector.extensions(), [])

defmodule PgBench do
  @db "knowseek_bench_storage"
  @n 100_000
  @vector_queries 50
  @text_queries 100
  # The app's HNSW scan settings (config.exs, Knowseek.Search.ef_search/1).
  @max_scan_tuples 20_000

  def run do
    Bench.memory_guard!("pgvector")
    admin = connect("postgres")
    Postgrex.query!(admin, "drop database if exists #{@db}", [])
    Postgrex.query!(admin, "create database #{@db}", [])

    try do
      conn = connect(@db)
      result = measure(conn)
      GenServer.stop(conn)
      Bench.write_result("pgvector-100000", result)
      IO.inspect(result, label: "pgvector", limit: :infinity)
    after
      Postgrex.query!(admin, "drop database if exists #{@db} with (force)", [])

      [[count]] =
        Postgrex.query!(admin, "select count(*) from pg_database where datname = $1", [@db]).rows

      IO.puts("#{@db} dropped: #{count == 0}")
    end
  end

  defp connect(database) do
    {:ok, conn} =
      Postgrex.start_link(
        hostname: System.get_env("PGHOST", "localhost"),
        port: String.to_integer(System.get_env("PGPORT", "5432")),
        username: System.get_env("PGUSER", "postgres"),
        password: System.get_env("PGPASSWORD", "postgres"),
        database: database,
        types: BenchTypes,
        pool_size: 1,
        timeout: :infinity
      )

    conn
  end

  defp q!(conn, sql, args \\ []), do: Postgrex.query!(conn, sql, args, timeout: :infinity)

  defp measure(conn) do
    q!(conn, "create extension vector")
    [[pg]] = q!(conn, "show server_version").rows
    [[pgvector]] = q!(conn, "select extversion from pg_extension where extname = 'vector'").rows

    q!(conn, """
    create table chunks (
      id bigint primary key,
      content text not null,
      embedding vector(1024),
      search_vector tsvector generated always as (to_tsvector('english', content)) stored
    )
    """)

    q!(conn, "create index chunks_search_vector_index on chunks using gin (search_vector)")

    source = Bench.Synthetic.source()
    batches = div(@n, Bench.Synthetic.batch_size())

    insert_ms =
      Enum.reduce(0..(batches - 1), 0, fn index, acc ->
        rows = Bench.Synthetic.batch(source, index, @n)
        {us, _} = :timer.tc(fn -> insert(conn, "chunks", rows) end)
        acc + us / 1000
      end)

    q!(conn, "vacuum analyze chunks")
    {hnsw_us, _} = :timer.tc(fn -> build_hnsw(conn, "chunks_embedding_index", "chunks") end)
    q!(conn, "analyze chunks")

    sizes =
      for {name, sql} <- [
            table_with_toast: "select pg_table_size('chunks')",
            hnsw: "select pg_relation_size('chunks_embedding_index')",
            gin: "select pg_relation_size('chunks_search_vector_index')",
            total: "select pg_total_relation_size('chunks')"
          ],
          into: %{} do
        [[bytes]] = q!(conn, sql).rows
        {name, Bench.mb(bytes)}
      end

    [[rows, vector_bytes, hnsw_pages]] =
      q!(
        conn,
        "select count(*), avg(pg_column_size(embedding))::int, pg_relation_size('chunks_embedding_index') / current_setting('block_size')::int from chunks"
      ).rows

    sizes =
      Map.merge(sizes, %{
        rows: rows,
        avg_stored_vector_bytes: vector_bytes,
        hnsw_pages: hnsw_pages
      })

    all = Bench.read_vectors(Bench.path("real/queries.f32"))
    vectors = all |> Enum.take_every(4) |> Enum.take(@vector_queries)

    texts =
      Bench.path("real/queries.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!(&1)["text"])
      |> Enum.take(@text_queries)

    %{
      n: @n,
      versions: %{postgres: pg, pgvector: pgvector},
      insert_s_with_gin: Float.round(insert_ms / 1000, 1),
      hnsw_build_s: Float.round(hnsw_us / 1_000_000, 1),
      size_mb: sizes,
      synthetic: vector_runs(conn, "chunks", vectors),
      fts: fts_runs(conn, texts),
      real: real(conn, all)
    }
  end

  defp insert(conn, table, rows) do
    for part <- Enum.chunk_every(rows, 1000) do
      ids = Enum.map(part, &elem(&1, 0))
      texts = Enum.map(part, &elem(&1, 3))
      vectors = Enum.map(part, &Pgvector.new(Bench.from_f32(elem(&1, 1))))

      if table == "chunks" do
        q!(
          conn,
          "insert into chunks (id, content, embedding) select * from unnest($1::bigint[], $2::text[], $3::vector[])",
          [ids, texts, vectors]
        )
      else
        q!(
          conn,
          "insert into #{table} (id, embedding) select * from unnest($1::bigint[], $2::vector[])",
          [ids, vectors]
        )
      end
    end
  end

  # HNSW at k=10 (ef_search 40, pgvector's default) and at the app's k=400
  # (ef_search 400, iterative scan strict_order), each against an exact scan.
  defp vector_runs(conn, table, vectors) do
    for {k, ef, iterative} <- [{10, 40, "off"}, {400, 400, "strict_order"}] do
      {exact_times, exact} = timed(conn, table, vectors, k, exact: true)
      {times, approx} = timed(conn, table, vectors, k, ef: ef, iterative: iterative)

      %{
        k: k,
        ef_search: ef,
        iterative_scan: iterative,
        hnsw: Bench.stats(times),
        exact_scan: Bench.stats(exact_times),
        recall: Bench.recall(approx, exact),
        planner_picks_hnsw_unforced:
          planner_picks_hnsw?(conn, table, hd(vectors), k, ef, iterative)
      }
    end
  end

  # The timed HNSW runs turn sequential scans off so they measure the index;
  # this records what the planner picks on its own with the app's settings.
  defp planner_picks_hnsw?(conn, table, v, k, ef, iterative) do
    {:ok, plan} =
      Postgrex.transaction(conn, fn c ->
        scan_settings(c, ef, iterative)

        q!(c, "explain select id from #{table} order by embedding <=> $1 limit $2", [
          Pgvector.new(v),
          k
        ]).rows
      end)

    plan |> List.flatten() |> Enum.any?(&String.contains?(&1, "Index Scan"))
  end

  defp scan_settings(c, ef, iterative) do
    q!(
      c,
      "select set_config('hnsw.ef_search', $1, true), set_config('hnsw.iterative_scan', $2, true), set_config('hnsw.max_scan_tuples', $3, true)",
      [
        Integer.to_string(ef),
        iterative,
        Integer.to_string(@max_scan_tuples)
      ]
    )
  end

  defp timed(conn, table, vectors, k, opts) do
    Bench.time_queries(vectors, fn v ->
      {:ok, ids} =
        Postgrex.transaction(conn, fn c ->
          if opts[:exact] do
            q!(c, "set local enable_indexscan = off")
          else
            scan_settings(c, opts[:ef], opts[:iterative])
            q!(c, "set local enable_seqscan = off")
          end

          q!(c, "select id from #{table} order by embedding <=> $1 limit $2", [Pgvector.new(v), k]).rows
          |> Enum.map(&hd/1)
        end)

      ids
    end)
  end

  # Today's keyword query: websearch_to_tsquery + ts_rank_cd over the GIN index.
  defp fts_runs(conn, texts) do
    for k <- [10, 400] do
      {times, results} =
        Bench.time_queries(
          texts,
          fn text ->
            q!(
              conn,
              """
              select id from chunks
              where search_vector @@ websearch_to_tsquery('english', $1)
              order by ts_rank_cd(search_vector, websearch_to_tsquery('english', $1)) desc
              limit $2
              """,
              [text, k]
            ).rows
          end,
          # Warm-up runs every text once, as in scale.exs.
          length(texts)
        )

      hits = Enum.map(results, &length/1)

      Map.merge(Bench.stats(times), %{
        k: k,
        queries_with_hits: Enum.count(hits, &(&1 > 0)),
        median_hits: Enum.at(Enum.sort(hits), div(length(hits), 2))
      })
    end
  end

  # Recall on the real bge-m3 vectors: every query text, against an exact scan.
  defp real(conn, queries) do
    chunks = Bench.read_vectors(Bench.path("real/chunks.f32"))
    q!(conn, "create table real_chunks (id bigint primary key, embedding vector(1024))")

    rows =
      chunks |> Enum.with_index(1) |> Enum.map(fn {v, id} -> {id, Bench.f32(v), nil, nil} end)

    insert(conn, "real_chunks", rows)
    build_hnsw(conn, "real_chunks_embedding_index", "real_chunks")
    q!(conn, "analyze real_chunks")

    %{
      chunks: length(chunks),
      queries: length(queries),
      runs: vector_runs(conn, "real_chunks", queries)
    }
  end

  defp build_hnsw(conn, name, table) do
    q!(conn, "set maintenance_work_mem = '1GB'")
    q!(conn, "set max_parallel_maintenance_workers = 0")
    q!(conn, "create index #{name} on #{table} using hnsw (embedding vector_cosine_ops)")
    q!(conn, "reset maintenance_work_mem")
    q!(conn, "reset max_parallel_maintenance_workers")
  end
end

PgBench.run()
