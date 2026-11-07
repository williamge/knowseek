# Shared helpers for the storage benchmarks. Loaded by the other scripts with
# `Code.require_file("bench_helpers.exs", __DIR__)` after their `Mix.install`.
defmodule Bench do
  @moduledoc false

  alias Exqlite.Sqlite3, as: S

  @dims 1024

  # sqlite-vec loadable builds for macOS arm64, from the GitHub releases.
  # The checksums are the release assets' own `digest` fields.
  @vec_builds %{
    "0.1.9" => "8282126333399ddfe98bbbcc7a1936e7252625aac49df056a98be602e46bfd29",
    "0.1.10-alpha.4" => "9c4c3c9fee1cd68d07028f90c9e31b67f13ca1a1737435ae569e8fe7a17b5a91"
  }

  def dims, do: @dims
  def dir, do: System.get_env("BENCH_DIR", "/tmp/knowseek-bench")
  def path(rel), do: Path.join(dir(), rel)
  def vec_versions, do: Map.keys(@vec_builds)

  ## sqlite-vec

  @doc "Downloads, checks and unpacks one sqlite-vec build; returns the path for load_extension."
  def ensure_vec(version) do
    sha = Map.fetch!(@vec_builds, version)
    ext_dir = path("ext/#{version}")
    lib = Path.join(ext_dir, "vec0")

    unless File.exists?(lib <> ".dylib") do
      File.mkdir_p!(ext_dir)
      name = "sqlite-vec-#{version}-loadable-macos-aarch64.tar.gz"
      url = "https://github.com/asg017/sqlite-vec/releases/download/v#{version}/#{name}"
      body = Req.get!(url).body
      actual = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      if actual != sha, do: raise("checksum mismatch for #{name}: #{actual}")
      :ok = :erl_tar.extract({:binary, body}, [:compressed, cwd: String.to_charlist(ext_dir)])
    end

    lib
  end

  @doc "Opens a SQLite file with sqlite-vec loaded and the pragmas an app would set."
  def open(file, vec_version \\ "0.1.9") do
    {:ok, conn} = S.open(file)
    :ok = S.enable_load_extension(conn, true)
    :ok = S.execute(conn, "select load_extension('#{ensure_vec(vec_version)}')")
    :ok = S.enable_load_extension(conn, false)

    for pragma <- [
          "journal_mode = WAL",
          "synchronous = NORMAL",
          # 64 MB page cache and 1 GB mmap, as in the earlier spike's "tuned" setting.
          "cache_size = -65536",
          "mmap_size = 1073741824"
        ] do
      query!(conn, "pragma " <> pragma)
    end

    conn
  end

  def close(conn), do: S.close(conn)
  def exec!(conn, sql), do: :ok = S.execute(conn, sql)

  def query!(conn, sql, args \\ []) do
    {:ok, stmt} = S.prepare(conn, sql)
    :ok = S.bind(stmt, args)
    {:ok, rows} = S.fetch_all(conn, stmt)
    :ok = S.release(conn, stmt)
    rows
  end

  @doc "Runs `sql` once per argument list inside one transaction."
  def insert_all!(conn, sql, arg_lists) do
    exec!(conn, "begin")
    {:ok, stmt} = S.prepare(conn, sql)

    for args <- arg_lists do
      :ok = S.bind(stmt, args)
      :done = S.step(conn, stmt)
      :ok = S.reset(stmt)
    end

    :ok = S.release(conn, stmt)
    exec!(conn, "commit")
  end

  def versions(conn) do
    [[sqlite, vec]] = query!(conn, "select sqlite_version(), vec_version()")
    %{sqlite: sqlite, sqlite_vec: vec}
  end

  @doc "Checkpoints the WAL so the main file holds everything, then returns its size in bytes."
  def file_size(conn, file) do
    query!(conn, "pragma wal_checkpoint(TRUNCATE)")
    File.stat!(file).size + wal_size(file)
  end

  defp wal_size(file) do
    case File.stat(file <> "-wal") do
      {:ok, stat} -> stat.size
      _ -> 0
    end
  end

  ## Vectors

  def f32(list), do: for(x <- list, into: <<>>, do: <<x::float-32-little>>)
  def from_f32(bin), do: for(<<x::float-32-little <- bin>>, do: x)

  def normalize(list) do
    norm = :math.sqrt(Enum.reduce(list, 0.0, fn x, acc -> acc + x * x end))
    Enum.map(list, &(&1 / norm))
  end

  @doc "int8 with one fixed scale for the whole data set (sqlite-vec's 'unit' maps [-1, 1] instead)."
  def int8(list, scale),
    do: for(x <- list, into: <<>>, do: <<max(-128, min(127, round(x * scale)))::signed-8>>)

  def dot(a, b), do: Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)

  @doc "Reads a file of concatenated float32 vectors into a list of lists."
  def read_vectors(file) do
    for <<v::binary-size(@dims * 4) <- File.read!(file)>>, do: from_f32(v)
  end

  ## Measuring

  @doc "Times `fun` over `queries` after `warmup` untimed calls; returns ms per query and the results."
  def time_queries(queries, fun, warmup \\ 5) do
    queries |> Enum.take(warmup) |> Enum.each(fun)

    {times, results} =
      queries
      |> Enum.map(fn q ->
        {us, result} = :timer.tc(fn -> fun.(q) end)
        {us / 1000, result}
      end)
      |> Enum.unzip()

    {times, results}
  end

  def stats(times) do
    sorted = Enum.sort(times)
    n = length(sorted)
    pick = fn p -> Enum.at(sorted, min(n - 1, floor(p * n))) end
    %{p50: Float.round(pick.(0.5), 2), p95: Float.round(pick.(0.95), 2), n: n}
  end

  def recall(approx, exact) do
    approx
    |> Enum.zip(exact)
    |> Enum.map(fn {a, e} ->
      MapSet.size(MapSet.intersection(MapSet.new(a), MapSet.new(e))) / max(1, length(e))
    end)
    |> then(&Float.round(Enum.sum(&1) / length(&1), 4))
  end

  def rss_mb do
    {out, 0} = System.cmd("ps", ["-o", "rss=", "-p", System.pid()])
    out |> String.trim() |> String.to_integer() |> div(1024)
  end

  @doc "macOS 'System-wide memory free percentage' from memory_pressure."
  def memory_free_pct do
    {out, 0} = System.cmd("memory_pressure", [])
    [_, pct] = Regex.run(~r/free percentage: (\d+)%/, out)
    String.to_integer(pct)
  end

  def swapouts do
    {out, 0} = System.cmd("vm_stat", [])
    [_, n] = Regex.run(~r/Swapouts:\s+(\d+)/, out)
    String.to_integer(n)
  end

  def disk_free_gib(dir \\ dir()) do
    {out, 0} = System.cmd("df", ["-k", dir])
    [_, line] = String.split(out, "\n", trim: true)
    kb = line |> String.split() |> Enum.at(3) |> String.to_integer()
    kb / 1024 / 1024
  end

  @doc "Stops with a message if the machine has less free memory than `min_pct`."
  def memory_guard!(
        label,
        min_pct \\ String.to_integer(System.get_env("BENCH_MIN_FREE_PCT", "15"))
      ) do
    pct = memory_free_pct()

    if pct < min_pct do
      raise "memory guard: #{pct}% free before #{label}, need #{min_pct}%. Close something or skip this step."
    end

    pct
  end

  def write_result(name, data) do
    File.mkdir_p!(path("results"))
    File.write!(path("results/#{name}.json"), Jason.encode!(data, pretty: true))
  end

  def mb(bytes), do: Float.round(bytes / 1_048_576, 1)

  ## Text

  @doc "FTS5 query with AND semantics: every word quoted, as websearch_to_tsquery ANDs words."
  def fts_query(text) do
    Regex.scan(~r/[\p{L}\p{N}]+/u, String.downcase(text))
    |> List.flatten()
    |> Enum.map_join(" ", &~s("#{&1}"))
  end
end

defmodule Bench.Synthetic do
  @moduledoc """
  Clustered synthetic chunks, deterministic per (batch index).

  Vector: a real bge-m3 chunk vector plus Gaussian noise (sigma 0.02 per
  dimension, so about 0.84 cosine to its base), normalized. Text: random
  sentences from the real chunks, up to about 1,000 characters, so FTS5 sees
  real words at real frequencies.
  """

  @sigma 0.02
  @batch 5_000

  def batch_size, do: @batch

  @doc "Loads the real vectors and sentences the generator draws from."
  def source do
    # Binaries, not lists: the tasks then share them instead of copying 5,000 lists.
    size = Bench.dims() * 4

    bases =
      for(<<v::binary-size(^size) <- File.read!(Bench.path("real/chunks.f32"))>>, do: v)
      |> List.to_tuple()

    sentences =
      Bench.path("real/chunks.jsonl")
      |> File.stream!()
      |> Enum.flat_map(&String.split(Jason.decode!(&1)["text"], ~r/(?<=[.!?])\s+/))
      |> Enum.filter(&(String.length(&1) > 20))
      |> List.to_tuple()

    scale =
      Bench.path("real/meta.json") |> File.read!() |> Jason.decode!() |> Map.fetch!("int8_scale")

    %{bases: bases, sentences: sentences, scale: scale}
  end

  @doc "Rows of batch `index` (ids from index * batch + 1): {id, f32 blob, int8 blob, text}."
  def batch(source, index, n) do
    first = index * @batch + 1
    last = min(n, first + @batch - 1)
    # Split the batch over the cores. Each part is seeded with its first id, an
    # integer (a {batch, part, c} tuple seed repeated rows across parts).
    parts = Enum.chunk_every(first..last//1, 625)

    parts
    |> Task.async_stream(fn ids -> rows(source, ids, hd(ids)) end,
      max_concurrency: System.schedulers_online(),
      timeout: :infinity
    )
    |> Enum.flat_map(fn {:ok, rows} -> rows end)
  end

  defp rows(%{bases: bases, sentences: sentences, scale: scale}, ids, seed) do
    :rand.seed(:exsss, seed)

    for id <- ids do
      base = elem(bases, :rand.uniform(tuple_size(bases)) - 1)

      v =
        base |> Bench.from_f32() |> Enum.map(&(&1 + @sigma * :rand.normal())) |> Bench.normalize()

      {id, Bench.f32(v), Bench.int8(v, scale), text(sentences, "")}
    end
  end

  defp text(_sentences, acc) when byte_size(acc) > 900, do: acc

  defp text(sentences, acc) do
    s = elem(sentences, :rand.uniform(tuple_size(sentences)) - 1)
    text(sentences, if(acc == "", do: s, else: acc <> " " <> s))
  end
end
