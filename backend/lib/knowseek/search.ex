defmodule Knowseek.Search do
  @moduledoc """
  Reads from the search index.

  `search/2` runs a hybrid search over chunks:

    1. full-text search on the generated `search_vector` column
    2. vector search on `embedding` (cosine distance, HNSW index)

  It merges the two ranked lists with reciprocal rank fusion (RRF), drops
  the chunks that are not relevant (see `Knowseek.Search.Hit.relevant?/2`),
  and groups the rest by document. A document is one hit: its best chunk
  supplies the hit's chunk fields and score (never a sum of chunk scores),
  and its other relevant chunks are the hit's `passages`, best first, at
  most `:max_passages`. Then it assesses coverage with
  `Knowseek.Search.Coverage`. A query that the index does not cover returns
  no hits, not the nearest unrelated chunks. When fewer than `limit`
  documents match, it returns fewer hits.

  Each ranked list fetches `limit * :candidate_factor` chunks, so that
  grouping still fills `limit` documents. See ADR 0011.

  This module only reads. Deciding what to do about weak coverage is the
  job of `Knowseek.Lookup`.
  """
  import Ecto.Query
  import Pgvector.Ecto.Query

  alias Knowseek.Documents.{Chunk, Document}
  alias Knowseek.Embeddings
  alias Knowseek.Repo
  alias Knowseek.Search.{Coverage, Hit}

  # Standard RRF constant. Dampens the weight of top ranks.
  @rrf_k 60

  # pgvector rejects `hnsw.ef_search` above 1000.
  @max_ef_search 1000

  @type result :: %{hits: [Hit.t()], coverage: Coverage.t()}

  @spec search(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, config(:default_limit))
    candidates = limit * config(:candidate_factor)
    min_similarity = Keyword.get(opts, :min_similarity, config(:min_similarity))

    with {:ok, [vector]} <- Embeddings.embed([query], input_type: :query) do
      embedding = Pgvector.new(vector)
      keyword = keyword_matches(query, candidates)
      semantic = semantic_matches(embedding, candidates)

      hits =
        keyword
        |> fuse(semantic)
        |> Enum.filter(&Hit.relevant?(&1, min_similarity))
        |> group_by_document(Keyword.get(opts, :max_passages, config(:max_passages)))
        |> Enum.take(limit)
        |> load_hits()

      coverage = Coverage.assess(hits, Keyword.put(opts, :limit, limit))
      {:ok, %{hits: hits, coverage: coverage}}
    end
  end

  # Returns chunk ids in rank order.
  defp keyword_matches(query, limit) do
    Repo.all(
      from c in Chunk,
        where: fragment("? @@ websearch_to_tsquery('english', ?)", c.search_vector, ^query),
        order_by: [
          desc:
            fragment("ts_rank_cd(?, websearch_to_tsquery('english', ?))", c.search_vector, ^query)
        ],
        limit: ^limit,
        select: c.id
    )
  end

  # Returns {chunk_id, cosine_similarity} in rank order.
  #
  # An HNSW index scan returns at most `hnsw.ef_search` rows (default 40), so
  # a larger `limit` would silently return 40. Raise it for this query only.
  defp semantic_matches(embedding, limit) do
    {:ok, rows} =
      Repo.transaction(fn ->
        Repo.query!("SELECT set_config('hnsw.ef_search', $1, true)", [
          Integer.to_string(min(max(limit, 40), @max_ef_search))
        ])

        Repo.all(
          from c in Chunk,
            where: not is_nil(c.embedding),
            order_by: cosine_distance(c.embedding, ^embedding),
            limit: ^limit,
            select: {c.id, 1 - cosine_distance(c.embedding, ^embedding)}
        )
      end)

    rows
  end

  defp fuse(keyword_ids, semantic) do
    keyword_ranks = keyword_ids |> Enum.with_index(1) |> Map.new()

    semantic_ranks =
      semantic |> Enum.with_index(1) |> Map.new(fn {{id, sim}, rank} -> {id, {rank, sim}} end)

    (keyword_ids ++ Enum.map(semantic, &elem(&1, 0)))
    |> Enum.uniq()
    |> Enum.map(fn id ->
      keyword_rank = Map.get(keyword_ranks, id)
      {semantic_rank, similarity} = Map.get(semantic_ranks, id, {nil, nil})

      %{
        chunk_id: id,
        keyword_rank: keyword_rank,
        semantic_rank: semantic_rank,
        similarity: similarity,
        score: rrf(keyword_rank) + rrf(semantic_rank)
      }
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp rrf(nil), do: 0.0
  defp rrf(rank), do: 1.0 / (@rrf_k + rank)

  # Turns ranked chunks into one entry per document, best document first.
  # Each entry is the best chunk's fused entry plus `:document_id` and
  # `:passages` (the other chunks, best first, capped). Only the best chunk
  # of a document gives the document's score: scores are not summed.
  defp group_by_document([], _max_passages), do: []

  defp group_by_document(ranked, max_passages) do
    ids = Enum.map(ranked, & &1.chunk_id)

    document_ids =
      Repo.all(from c in Chunk, where: c.id in ^ids, select: {c.id, c.document_id})
      |> Map.new()

    ranked
    |> Enum.filter(&Map.has_key?(document_ids, &1.chunk_id))
    |> Enum.group_by(&document_ids[&1.chunk_id])
    |> Enum.map(fn {document_id, [best | rest]} ->
      best
      |> Map.put(:document_id, document_id)
      |> Map.put(:passages, Enum.take(rest, max_passages))
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp load_hits([]), do: []

  defp load_hits(entries) do
    chunk_ids =
      Enum.flat_map(entries, fn entry ->
        [entry.chunk_id | Enum.map(entry.passages, & &1.chunk_id)]
      end)

    rows =
      Repo.all(
        from c in Chunk,
          join: d in Document,
          on: d.id == c.document_id,
          where: c.id in ^chunk_ids,
          select:
            {c.id,
             %{
               url: d.url,
               title: d.title,
               content: c.content,
               published_at: d.published_at,
               fetched_at: d.fetched_at
             }}
      )
      |> Map.new()

    for entry <- entries, row = rows[entry.chunk_id], row != nil do
      passages =
        for passage <- entry.passages, passage_row = rows[passage.chunk_id], passage_row != nil do
          %{chunk_id: passage.chunk_id, content: passage_row.content, score: passage.score}
        end

      struct!(Hit, row |> Map.merge(entry) |> Map.put(:passages, passages))
    end
  end

  defp config(key), do: Application.get_env(:knowseek, __MODULE__, []) |> Keyword.fetch!(key)
end
