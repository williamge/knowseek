# Step 2: quality of int8 and 1-bit vectors on real bge-m3 vectors.
#
# Loads the vectors from real_vectors.exs into one SQLite file (float32, int8,
# 1-bit vec0 tables) and measures recall@10 and recall@400 against exact
# float32 search, for 200 real query texts. 400 is what the app asks for
# (limit 10 times candidate_factor 40).
#
# Run: elixir docs/notes/bench/recall.exs   (after real_vectors.exs)
Mix.install([{:exqlite, "~> 0.43"}, {:req, "~> 0.5"}, {:jason, "~> 1.4"}])
Code.require_file("bench_helpers.exs", __DIR__)

defmodule Recall do
  @ks [10, 400]
  @oversamples [2, 4, 8, 16]

  def run do
    meta = Bench.path("real/meta.json") |> File.read!() |> Jason.decode!()
    scale = meta["int8_scale"]
    chunks = Bench.read_vectors(Bench.path("real/chunks.f32"))
    queries = Bench.read_vectors(Bench.path("real/queries.f32"))
    n = length(chunks)

    file = Bench.path("real/real.db")
    File.rm(file)
    conn = Bench.open(file)

    for sql <- [
          "create virtual table vf using vec0(embedding float[1024] distance_metric=cosine)",
          "create virtual table vi using vec0(embedding int8[1024] distance_metric=cosine)",
          "create virtual table vu using vec0(embedding int8[1024] distance_metric=cosine)",
          "create virtual table vb using vec0(embedding bit[1024])",
          "create virtual table vc using vec0(embedding bit[1024])"
        ],
        do: Bench.exec!(conn, sql)

    rows = chunks |> Enum.with_index(1)

    Bench.insert_all!(
      conn,
      "insert into vf(rowid, embedding) values (?, ?)",
      for({v, id} <- rows, do: [id, {:blob, Bench.f32(v)}])
    )

    Bench.insert_all!(
      conn,
      "insert into vi(rowid, embedding) values (?, vec_int8(?))",
      for({v, id} <- rows, do: [id, {:blob, Bench.int8(v, scale)}])
    )

    Bench.exec!(
      conn,
      "insert into vu(rowid, embedding) select rowid, vec_quantize_int8(embedding, 'unit') from vf"
    )

    Bench.exec!(
      conn,
      "insert into vb(rowid, embedding) select rowid, vec_quantize_binary(embedding) from vf"
    )

    # Sign bits of the vector minus the corpus mean: bge-m3 dimensions are not centred on 0.
    mean = mean(chunks)
    center = fn v -> Bench.f32(Enum.zip_with(v, mean, &(&1 - &2))) end

    Bench.insert_all!(
      conn,
      "insert into vc(rowid, embedding) values (?, vec_quantize_binary(?))",
      for({v, id} <- rows, do: [id, {:blob, center.(v)}])
    )

    results =
      for k <- @ks do
        exact = Enum.map(queries, &knn(conn, "vf", {:blob, Bench.f32(&1)}, k))
        check_exact!(chunks, queries, exact, k)
        q8 = fn q -> {:blob, Bench.int8(q, scale)} end

        rows =
          [
            {"float32 (exact)", exact},
            {"int8, one fixed scale", Enum.map(queries, &knn(conn, "vi", q8.(&1), k))},
            {"int8, sqlite-vec 'unit'",
             Enum.map(queries, &knn(conn, "vu", {:blob, Bench.f32(&1)}, k))},
            {"1-bit only", Enum.map(queries, &knn(conn, "vb", {:blob, Bench.f32(&1)}, k))},
            {"1-bit centred only", Enum.map(queries, &knn(conn, "vc", {:blob, center.(&1)}, k))}
          ] ++
            for os <- @oversamples, k * os <= n do
              {"1-bit, float32 rescore, oversample #{os}",
               Enum.map(
                 queries,
                 &rescore(conn, {"vb", Bench.f32(&1)}, "vf", &1, k, k * os, :f32, scale)
               )}
            end ++
            for os <- [4, 8], k * os <= n do
              {"1-bit, int8 rescore, oversample #{os}",
               Enum.map(
                 queries,
                 &rescore(conn, {"vb", Bench.f32(&1)}, "vi", &1, k, k * os, :int8, scale)
               )}
            end ++
            for os <- [4, 8, 16], k * os <= n do
              {"1-bit centred, float32 rescore, oversample #{os}",
               Enum.map(
                 queries,
                 &rescore(conn, {"vc", center.(&1)}, "vf", &1, k, k * os, :f32, scale)
               )}
            end

        for {name, approx} <- rows, do: %{k: k, config: name, recall: Bench.recall(approx, exact)}
      end
      |> List.flatten()

    sizes =
      for t <- ~w(vf vi vu vb vc) do
        [[bytes]] =
          Bench.query!(conn, "select sum(pgsize) from dbstat where name like ?", [t <> "_%"])

        {t, Bench.mb(bytes)}
      end

    out = %{
      meta: meta,
      versions: Bench.versions(conn),
      chunks: n,
      queries: length(queries),
      results: results,
      table_mb: Map.new(sizes)
    }

    Bench.write_result("recall", out)
    IO.puts("| k | Config | Recall |\n| --- | --- | --- |")
    for r <- results, do: IO.puts("| #{r.k} | #{r.config} | #{r.recall} |")
    IO.inspect(out.versions, label: "versions")
  end

  defp knn(conn, table, query, k) do
    # Queries go in as float32 and are quantized by the same sqlite-vec functions as the rows.
    type =
      %{
        "vi" => "vec_int8(?)",
        "vu" => "vec_quantize_int8(?, 'unit')",
        "vb" => "vec_quantize_binary(?)",
        "vc" => "vec_quantize_binary(?)",
        "vf" => "?"
      }[table]

    conn
    |> Bench.query!("select rowid from #{table} where embedding match #{type} and k = ?", [
      query,
      k
    ])
    |> Enum.map(&hd/1)
  end

  defp rescore(conn, {coarse_table, coarse_query}, table, q, k, coarse, kind, scale) do
    {fine, wrap} =
      if kind == :f32,
        do: {{:blob, Bench.f32(q)}, "?2"},
        else: {{:blob, Bench.int8(q, scale)}, "vec_int8(?2)"}

    conn
    |> Bench.query!(
      """
      with c as (select rowid from #{coarse_table} where embedding match vec_quantize_binary(?1) and k = ?3)
      select c.rowid from c join #{table} t on t.rowid = c.rowid
      order by vec_distance_cosine(t.embedding, #{wrap}) limit ?4
      """,
      [{:blob, coarse_query}, fine, coarse, k]
    )
    |> Enum.map(&hd/1)
  end

  defp mean(vectors) do
    n = length(vectors)
    vectors |> Enum.zip_with(&Enum.sum/1) |> Enum.map(&(&1 / n))
  end

  # sqlite-vec's float32 scan must match exact cosine computed here (first 5 queries).
  defp check_exact!(chunks, queries, exact, k) do
    for {q, ids} <- Enum.zip(Enum.take(queries, 5), Enum.take(exact, 5)) do
      mine =
        chunks
        |> Enum.with_index(1)
        |> Enum.map(fn {v, id} -> {Bench.dot(q, v), id} end)
        |> Enum.sort(:desc)
        |> Enum.take(k)
        |> Enum.map(&elem(&1, 1))

      overlap = MapSet.size(MapSet.intersection(MapSet.new(mine), MapSet.new(ids))) / k
      if overlap < 0.99, do: raise("sqlite-vec float32 differs from exact cosine: #{overlap}")
    end
  end
end

Recall.run()
