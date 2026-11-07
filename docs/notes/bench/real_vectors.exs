# Step 1: real bge-m3 vectors for the recall measurements.
#
# Fetches long random English Wikipedia articles (3 requests at a time at most),
# chunks them like Knowseek.Documents.Chunker (1,200 characters), and embeds the
# chunks and the query texts with bge-m3 through the local Ollama.
#
# Writes to $BENCH_DIR/real (default /tmp/knowseek-bench/real):
#   chunks.jsonl, chunks.f32    one chunk per line; float32 vectors in the same order
#   queries.jsonl, queries.f32  article titles: half from the corpus, half not
#   meta.json                   versions, counts, the int8 scale
# A second run reuses what is there (the embedding resumes).
#
# Run: elixir docs/notes/bench/real_vectors.exs   (BENCH_REAL_CHUNKS, default 5000)
Mix.install([{:exqlite, "~> 0.43"}, {:req, "~> 0.5"}, {:jason, "~> 1.4"}])
Code.require_file("bench_helpers.exs", __DIR__)

defmodule RealVectors do
  @api "https://en.wikipedia.org/w/api.php"
  @user_agent "Knowseek/0.1.0 (https://github.com/williamge/knowseek)"
  @ollama "http://localhost:11434"
  @max_chars 1_200
  @max_chunks_per_article 12
  @min_article_bytes 12_000
  @queries_per_kind 100
  @tail ~r/\n== (References|See also|Notes|External links|Further reading|Bibliography|Sources|Citations|Footnotes) ==.*/s

  def run do
    target = String.to_integer(System.get_env("BENCH_REAL_CHUNKS", "5000"))
    out = Bench.path("real")
    File.mkdir_p!(out)

    {chunks, queries} = fetch(out, target)
    embed(Path.join(out, "chunks.f32"), Enum.map(chunks, & &1["text"]))
    embed(Path.join(out, "queries.f32"), Enum.map(queries, & &1["text"]))
    write_meta(out, chunks, queries)
  end

  ## Wikipedia

  defp fetch(out, target) do
    chunks_file = Path.join(out, "chunks.jsonl")
    queries_file = Path.join(out, "queries.jsonl")

    if File.exists?(chunks_file) and File.exists?(queries_file) do
      {read_jsonl(chunks_file), read_jsonl(queries_file)}
    else
      {chunks, long_titles, short_titles} = collect(target, [], [], [])
      write_jsonl(chunks_file, chunks)

      queries =
        Enum.map(Enum.take(long_titles, @queries_per_kind), &%{"text" => &1, "in_corpus" => true}) ++
          Enum.map(
            Enum.take(short_titles, @queries_per_kind),
            &%{"text" => &1, "in_corpus" => false}
          )

      write_jsonl(queries_file, queries)
      {chunks, queries}
    end
  end

  defp collect(target, chunks, long_titles, short_titles) when length(chunks) >= target,
    do: {Enum.take(chunks, target), Enum.reverse(long_titles), Enum.reverse(short_titles)}

  defp collect(target, chunks, long_titles, short_titles) do
    pages =
      api!(
        generator: "random",
        grnnamespace: 0,
        grnlimit: 50,
        prop: "info"
      )["query"]["pages"]

    {long, short} = Enum.split_with(pages, &(&1["length"] >= @min_article_bytes))

    new_chunks =
      long
      |> Task.async_stream(&article_chunks(&1["title"]), max_concurrency: 3, timeout: 60_000)
      |> Enum.flat_map(fn {:ok, list} -> list end)

    IO.puts("chunks: #{length(chunks) + length(new_chunks)} / #{target}")

    collect(
      target,
      chunks ++ new_chunks,
      Enum.reverse(Enum.map(long, & &1["title"])) ++ long_titles,
      Enum.reverse(Enum.map(short, & &1["title"])) ++ short_titles
    )
  end

  defp article_chunks(title) do
    [page] = api!(prop: "extracts", explaintext: 1, redirects: 1, titles: title)["query"]["pages"]

    (page["extract"] || "")
    |> String.replace(@tail, "")
    |> chunk()
    |> Enum.take(@max_chunks_per_article)
    |> Enum.map(&%{"title" => title, "text" => &1})
  end

  defp api!(params) do
    params = Keyword.merge([action: "query", format: "json", formatversion: 2], params)
    Req.get!(@api, params: params, headers: [user_agent: @user_agent], retry: :transient).body
  end

  # The same rules as Knowseek.Documents.Chunker: pack paragraphs up to 1,200
  # characters, split longer paragraphs on spaces.
  defp chunk(text) do
    text
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.map(&(&1 |> String.split() |> Enum.join(" ")))
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "==")))
    |> Enum.flat_map(fn p ->
      if String.length(p) <= @max_chars, do: [p], else: pack(String.split(p, " "), " ")
    end)
    |> pack("\n\n")
  end

  defp pack(pieces, joiner) do
    pieces
    |> Enum.reduce([], fn
      piece, [] ->
        [piece]

      piece, [current | done] ->
        candidate = current <> joiner <> piece

        if String.length(candidate) <= @max_chars,
          do: [candidate | done],
          else: [piece, current | done]
    end)
    |> Enum.reverse()
  end

  ## Ollama

  defp embed(file, texts) do
    done = if File.exists?(file), do: div(File.stat!(file).size, Bench.dims() * 4), else: 0

    texts
    |> Enum.drop(done)
    |> Enum.chunk_every(20)
    |> Enum.with_index()
    |> Enum.each(fn {batch, i} ->
      %{"embeddings" => vectors} =
        Req.post!("#{@ollama}/api/embed",
          json: %{model: "bge-m3", input: batch},
          receive_timeout: 300_000
        ).body

      File.write!(file, Enum.map(vectors, &Bench.f32/1), [:append])

      if rem(i, 10) == 0,
        do: IO.puts("#{Path.basename(file)}: #{done + (i + 1) * 20} / #{length(texts)}")
    end)
  end

  defp write_meta(out, chunks, queries) do
    vectors = Bench.read_vectors(Path.join(out, "chunks.f32"))
    abs = vectors |> List.flatten() |> Enum.map(&abs/1) |> Enum.sort()
    max_abs = List.last(abs)
    p9999 = Enum.at(abs, floor(0.9999 * length(abs)))
    %{"version" => ollama_version} = Req.get!("#{@ollama}/api/version").body
    %{"models" => models} = Req.get!("#{@ollama}/api/tags").body
    model = Enum.find(models, &String.starts_with?(&1["name"], "bge-m3"))

    meta = %{
      chunks: length(chunks),
      articles: chunks |> Enum.map(& &1["title"]) |> Enum.uniq() |> length(),
      queries: length(queries),
      avg_chunk_chars:
        round(Enum.sum(Enum.map(chunks, &String.length(&1["text"]))) / length(chunks)),
      max_abs: max_abs,
      p9999_abs: p9999,
      # One scale for every vector: the largest value maps to 127, nothing clips.
      int8_scale: 127 / max_abs,
      ollama: ollama_version,
      model: %{name: model["name"], digest: model["digest"]},
      fetched_on: Date.to_iso8601(Date.utc_today())
    }

    File.write!(Path.join(out, "meta.json"), Jason.encode!(meta, pretty: true))
    IO.inspect(meta, label: "meta")
  end

  defp read_jsonl(file), do: file |> File.stream!() |> Enum.map(&Jason.decode!/1)

  defp write_jsonl(file, rows), do: File.write!(file, Enum.map(rows, &[Jason.encode!(&1), "\n"]))
end

RealVectors.run()
