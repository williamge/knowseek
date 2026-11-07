# Step 3: SQLite + sqlite-vec + FTS5 at a given chunk count, on synthetic data.
#
#   elixir docs/notes/bench/scale.exs build 100000            # load, sizes, insert time
#   elixir docs/notes/bench/scale.exs query 100000 0.1.9      # latency, RAM, recall vs float32
#   elixir docs/notes/bench/scale.exs query 100000 0.1.10-alpha.4
#
# One SQLite file per store under $BENCH_DIR/scale-<n>/, so each size is its own:
#   f32.db   vec0 float[1024], cosine
#   int8.db  vec0 int8[1024], cosine (one fixed scale, see real_vectors.exs)
#   bit.db   vec0 bit[1024] (sign bits), hamming
#   fts.db   chunks(id, content) plus an external-content FTS5 index (porter)
#   f32blob.db, int8blob.db   raw(id, v blob): plain rows to rescore from
# "1-bit + rescore" searches bit.db for k * 8 candidates and re-ranks them by
# cosine on f32blob.db (or int8blob.db) through ATTACH.
#
# Guards: the build stops if free memory is under BENCH_MIN_FREE_PCT (15%), and
# skips the float32 stores when one is over 2 GiB and the disk has less than
# BENCH_F32_MIN_FREE_GIB (15) free, or would keep less than 10 GiB free after
# the build. Data needs real_vectors.exs first.
Mix.install([{:exqlite, "~> 0.43"}, {:req, "~> 0.5"}, {:jason, "~> 1.4"}])
Code.require_file("bench_helpers.exs", __DIR__)

defmodule Scale do
  @oversample 8
  @ks [10, 400]
  @vector_queries 50
  @text_queries 100

  def main(["build", n]), do: build(String.to_integer(n))
  def main(["query", n, version]), do: query(String.to_integer(n), version)

  ## Build

  def build(n) do
    dir = Bench.path("scale-#{n}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    free_pct = Bench.memory_guard!("build #{n}")
    skipped = skipped(n)
    stores = ~w(f32 int8 bit fts f32blob int8blob) -- Map.keys(skipped)
    swap_before = Bench.swapouts()

    conns =
      Map.new(stores, fn store ->
        conn = Bench.open(Path.join(dir, "#{store}.db"))
        Enum.each(schema(store), &Bench.exec!(conn, &1))
        {store, conn}
      end)

    source = Bench.Synthetic.source()
    batches = div(n + Bench.Synthetic.batch_size() - 1, Bench.Synthetic.batch_size())

    insert_ms =
      Enum.reduce(0..(batches - 1), Map.new(stores, &{&1, 0}), fn index, acc ->
        rows = Bench.Synthetic.batch(source, index, n)

        if rem(index, 20) == 0,
          do: IO.puts("batch #{index + 1}/#{batches}, #{Bench.memory_free_pct()}% memory free")

        Map.new(acc, fn {store, ms} ->
          {us, :ok} = :timer.tc(fn -> insert(conns[store], store, rows) end)
          {store, ms + us / 1000}
        end)
      end)

    # Every generated row must differ (int8 blobs, first 64 bytes).
    [[distinct]] =
      Bench.query!(conns["int8blob"], "select count(distinct substr(v, 1, 64)) from raw")

    if distinct != n, do: raise("generator repeated rows: #{distinct} distinct of #{n}")

    sizes =
      Map.new(conns, fn {store, conn} ->
        size = Bench.file_size(conn, Path.join(dir, "#{store}.db"))
        Bench.close(conn)
        {store, Bench.mb(size)}
      end)

    result = %{
      n: n,
      stores: stores,
      skipped: skipped,
      insert_s: Map.new(insert_ms, fn {s, ms} -> {s, Float.round(ms / 1000, 1)} end),
      file_mb: sizes,
      memory_free_pct_before: free_pct,
      swapouts_during: Bench.swapouts() - swap_before,
      disk_free_gib_after: Float.round(Bench.disk_free_gib(), 1)
    }

    Bench.write_result("scale-#{n}-build", result)
    IO.inspect(result, label: "build")
  end

  # Disk guard: skip the two float32 stores (vec0 and blob) when one is over
  # 2 GiB and either the disk has less than BENCH_F32_MIN_FREE_GIB (15) free,
  # or less than 10 GiB would stay free after every store is written.
  defp skipped(n) do
    f32_gib = n * Bench.dims() * 4 / 1_073_741_824
    # f32 + f32blob, plus int8, int8blob, bit and fts (about 4 KB a row together).
    all_gib = 2 * f32_gib + n * 4_100 / 1_073_741_824
    min_free = String.to_integer(System.get_env("BENCH_F32_MIN_FREE_GIB", "15"))
    free = Bench.disk_free_gib()

    reason =
      "disk: #{Float.round(free, 1)} GiB free; the stores need #{Float.round(all_gib, 1)} GiB, " <>
        "each float32 store #{Float.round(f32_gib, 1)} GiB"

    if f32_gib > 2 and (free < min_free or free - all_gib < 10),
      do: %{"f32" => reason, "f32blob" => reason},
      else: %{}
  end

  defp schema("f32"),
    do: ["create virtual table v using vec0(embedding float[1024] distance_metric=cosine)"]

  defp schema("int8"),
    do: ["create virtual table v using vec0(embedding int8[1024] distance_metric=cosine)"]

  defp schema("bit"), do: ["create virtual table v using vec0(embedding bit[1024])"]
  # The rescoring source: plain rows, as the app's chunks table would hold them.
  defp schema("f32blob"), do: ["create table raw(id integer primary key, v blob not null)"]
  defp schema("int8blob"), do: ["create table raw(id integer primary key, v blob not null)"]

  defp schema("fts") do
    [
      "create table chunks(id integer primary key, content text not null)",
      "create virtual table chunks_fts using fts5(content, content='chunks', content_rowid='id', tokenize='porter unicode61')"
    ]
  end

  defp insert(conn, "f32", rows),
    do:
      Bench.insert_all!(
        conn,
        "insert into v(rowid, embedding) values (?, ?)",
        for({id, f, _, _} <- rows, do: [id, {:blob, f}])
      )

  defp insert(conn, "int8", rows),
    do:
      Bench.insert_all!(
        conn,
        "insert into v(rowid, embedding) values (?, vec_int8(?))",
        for({id, _, i, _} <- rows, do: [id, {:blob, i}])
      )

  defp insert(conn, "bit", rows),
    do:
      Bench.insert_all!(
        conn,
        "insert into v(rowid, embedding) values (?, vec_quantize_binary(?))",
        for({id, f, _, _} <- rows, do: [id, {:blob, f}])
      )

  defp insert(conn, "f32blob", rows),
    do:
      Bench.insert_all!(
        conn,
        "insert into raw(id, v) values (?, ?)",
        for({id, f, _, _} <- rows, do: [id, {:blob, f}])
      )

  defp insert(conn, "int8blob", rows),
    do:
      Bench.insert_all!(
        conn,
        "insert into raw(id, v) values (?, ?)",
        for({id, _, i, _} <- rows, do: [id, {:blob, i}])
      )

  defp insert(conn, "fts", rows) do
    Bench.insert_all!(
      conn,
      "insert into chunks(id, content) values (?, ?)",
      for({id, _, _, t} <- rows, do: [id, t])
    )

    ids = rows |> Enum.map(&elem(&1, 0))

    Bench.exec!(
      conn,
      "insert into chunks_fts(rowid, content) select id, content from chunks where id between #{hd(ids)} and #{List.last(ids)}"
    )
  end

  ## Query

  def query(n, version) do
    dir = Bench.path("scale-#{n}")
    build = Bench.path("results/scale-#{n}-build.json") |> File.read!() |> Jason.decode!()
    stores = build["stores"]
    Bench.memory_guard!("query #{n}")
    meta = Bench.path("real/meta.json") |> File.read!() |> Jason.decode!()
    all = Bench.read_vectors(Bench.path("real/queries.f32"))
    # Every 4th query: half of them are in-corpus titles, half not.
    vectors = all |> Enum.take_every(4) |> Enum.take(@vector_queries)

    texts =
      Bench.path("real/queries.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!(&1)["text"])
      |> Enum.take(@text_queries)

    plan =
      [
        {"float32", "f32", nil, &knn(&1, "?", Bench.f32(&2), &3)},
        {"int8", "int8", nil, &knn(&1, "vec_int8(?)", Bench.int8(&2, meta["int8_scale"]), &3)},
        {"1-bit only", "bit", nil, &knn(&1, "vec_quantize_binary(?)", Bench.f32(&2), &3)},
        {"1-bit + float32 rescore", "bit", "f32blob",
         &rescore(&1, "t.v, ?2", Bench.f32(&2), &2, &3)},
        {"1-bit + int8 rescore", "bit", "int8blob",
         &rescore(&1, "vec_int8(t.v), vec_int8(?2)", Bench.int8(&2, meta["int8_scale"]), &2, &3)}
      ]
      |> Enum.filter(fn {_, main, extra, _} ->
        main in stores and (extra == nil or extra in stores)
      end)

    vector_rows =
      for {name, main, extra, fun} <- plan do
        conn = Bench.open(Path.join(dir, "#{main}.db"), version)
        if extra, do: Bench.exec!(conn, "attach '#{Path.join(dir, extra <> ".db")}' as x")
        rss_before = Bench.rss_mb()

        per_k =
          for k <- @ks do
            {times, results} = Bench.time_queries(vectors, &fun.(conn, &1, k))
            {k, Bench.stats(times), results}
          end

        row = %{
          config: name,
          version: version,
          rss_delta_mb: Bench.rss_mb() - rss_before,
          per_k: per_k
        }

        Bench.close(conn)
        IO.puts("#{name}: #{inspect(Enum.map(per_k, fn {k, s, _} -> {k, s} end))}")
        row
      end

    vector_rows = add_recall(vector_rows)
    text_rows = if "fts" in stores, do: fts(dir, version, texts), else: []

    result = %{
      n: n,
      versions: versions(dir, stores, version),
      vector:
        Enum.map(vector_rows, fn r ->
          Map.update!(r, :per_k, &Enum.map(&1, fn {k, s, _} -> Map.put(s, :k, k) end))
        end),
      fts: text_rows,
      memory_free_pct_after: Bench.memory_free_pct()
    }

    Bench.write_result("scale-#{n}-query-#{version}", result)
    print(result)
  end

  defp knn(conn, wrap, blob, k) do
    conn
    |> Bench.query!("select rowid from v where embedding match #{wrap} and k = ?", [
      {:blob, blob},
      k
    ])
    |> Enum.map(&hd/1)
  end

  defp rescore(conn, distance_args, fine, q, k) do
    conn
    |> Bench.query!(
      """
      with c as (select rowid from v where embedding match vec_quantize_binary(?1) and k = ?3)
      select c.rowid from c join x.raw t on t.id = c.rowid
      order by vec_distance_cosine(#{distance_args}) limit ?4
      """,
      [{:blob, Bench.f32(q)}, {:blob, fine}, k * @oversample, k]
    )
    |> Enum.map(&hd/1)
  end

  # Recall against the float32 scan of the same synthetic rows, when f32.db exists.
  defp add_recall(rows) do
    case Enum.find(rows, &(&1.config == "float32")) do
      nil ->
        rows

      exact ->
        Enum.map(rows, fn row ->
          recalls =
            for {{k, _, approx}, {k, _, truth}} <- Enum.zip(row.per_k, exact.per_k),
                do: {k, Bench.recall(approx, truth)}

          Map.put(row, :recall, Map.new(recalls, fn {k, r} -> {"at_#{k}", r} end))
        end)
    end
  end

  defp fts(dir, version, texts) do
    conn = Bench.open(Path.join(dir, "fts.db"), version)
    rss_before = Bench.rss_mb()

    rows =
      for k <- @ks do
        # Warm-up runs every text once: each query touches other index pages.
        {times, results} =
          Bench.time_queries(
            texts,
            fn text ->
              Bench.query!(
                conn,
                "select rowid from chunks_fts where chunks_fts match ? order by rank limit ?",
                [Bench.fts_query(text), k]
              )
            end,
            length(texts)
          )

        hits = Enum.map(results, &length/1)

        Map.merge(Bench.stats(times), %{
          k: k,
          queries_with_hits: Enum.count(hits, &(&1 > 0)),
          median_hits: Enum.at(Enum.sort(hits), div(length(hits), 2))
        })
      end

    [[fts_bytes]] =
      Bench.query!(conn, "select sum(pgsize) from dbstat where name like 'chunks_fts%'")

    [[text_bytes]] = Bench.query!(conn, "select sum(pgsize) from dbstat where name = 'chunks'")
    rss = Bench.rss_mb() - rss_before
    Bench.close(conn)

    [
      %{
        config: "FTS5 (AND, bm25)",
        per_k: rows,
        rss_delta_mb: rss,
        fts_index_mb: Bench.mb(fts_bytes),
        text_mb: Bench.mb(text_bytes)
      }
    ]
  end

  defp versions(dir, stores, version) do
    conn = Bench.open(Path.join(dir, hd(stores) <> ".db"), version)
    v = Bench.versions(conn)
    Bench.close(conn)
    v
  end

  defp print(result) do
    IO.puts(
      "\n| Config | k | p50 ms | p95 ms | recall | RSS delta MB |\n| --- | --- | --- | --- | --- | --- |"
    )

    for row <- result.vector ++ result.fts, s <- row.per_k do
      recall = get_in(row, [Access.key(:recall, %{}), "at_#{s.k}"]) || "-"

      IO.puts(
        "| #{row.config} | #{s.k} | #{s.p50} | #{s.p95} | #{recall} | #{row.rss_delta_mb} |"
      )
    end

    IO.inspect(result.versions, label: "versions")
  end
end

Scale.main(System.argv())
