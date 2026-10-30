defmodule Knowseek.Search do
  @moduledoc """
  Reads from the search index.

  `search/2` runs a hybrid search over chunks:

    1. full-text search on the generated `search_vector` column
    2. vector search on `embedding` (cosine distance, HNSW index)

  It merges the two ranked lists with reciprocal rank fusion (RRF), then
  assesses coverage with `Knowseek.Search.Coverage`.

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

  @type result :: %{hits: [Hit.t()], coverage: Coverage.t()}

  @spec search(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, config(:default_limit))
    candidates = limit * 4

    with {:ok, [vector]} <- Embeddings.embed([query], input_type: :query) do
      embedding = Pgvector.new(vector)
      keyword = keyword_matches(query, candidates)
      semantic = semantic_matches(embedding, candidates)

      hits =
        keyword
        |> fuse(semantic)
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
  defp semantic_matches(embedding, limit) do
    Repo.all(
      from c in Chunk,
        where: not is_nil(c.embedding),
        order_by: cosine_distance(c.embedding, ^embedding),
        limit: ^limit,
        select: {c.id, 1 - cosine_distance(c.embedding, ^embedding)}
    )
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

  defp load_hits([]), do: []

  defp load_hits(ranked) do
    ids = Enum.map(ranked, & &1.chunk_id)

    rows =
      Repo.all(
        from c in Chunk,
          join: d in Document,
          on: d.id == c.document_id,
          where: c.id in ^ids,
          select:
            {c.id,
             %{
               document_id: d.id,
               url: d.url,
               title: d.title,
               content: c.content,
               published_at: d.published_at,
               fetched_at: d.fetched_at
             }}
      )
      |> Map.new()

    for entry <- ranked, row = rows[entry.chunk_id], row != nil do
      struct!(Hit, Map.merge(row, entry))
    end
  end

  defp config(key), do: Application.get_env(:knowseek, __MODULE__, []) |> Keyword.fetch!(key)
end
