defmodule Knowseek.Search do
  @moduledoc """
  Reads from the search index.

  `search/2` runs a hybrid search over chunks:

    1. full-text search in the FTS5 table `chunks_fts`, ranked by `bm25`;
       `Knowseek.Search.FtsQuery` turns the query text into the FTS5 query
    2. vector search in the sqlite-vec table `chunk_vectors` (cosine
       distance, an exact scan)

  It merges the two ranked lists with reciprocal rank fusion (RRF), drops
  the chunks that are not relevant (see `Knowseek.Search.Hit.relevant?/2`),
  and groups the rest by document. A document is one hit: its best chunk
  supplies the hit's chunk fields and score (never a sum of chunk scores),
  and its other relevant chunks are the hit's `passages`, best first, at
  most `:max_passages`. Then it assesses coverage with
  `Knowseek.Search.Coverage`. A query that the index does not cover returns
  no hits, not the nearest unrelated chunks. When fewer than `limit`
  documents match, it returns fewer hits.

  After grouping, a document's score is multiplied by a bounded prior from
  its `monthly_views` (`prior_factor/3`, options `:prior_weight` and
  `:prior_saturation_views`, ADR 0018), and the hits are ordered again. It
  breaks near-ties in favour of the more widely read document. A document
  without a signal keeps its score and, among such documents, its order.

  Each ranked list fetches `limit * :candidate_factor` chunks (the vector
  list at most 4096, sqlite-vec's cap), so that grouping still fills `limit`
  documents. See ADR 0011.

  `count_near/2` counts the stored documents near a vector, for the background
  crawl (#89).

  This module only reads. Deciding what to do about weak coverage is the
  job of `Knowseek.Lookup`.
  """
  import Ecto.Query

  alias Knowseek.Documents.{Chunk, Document, Vector}
  alias Knowseek.Embeddings
  alias Knowseek.Repo
  alias Knowseek.Search.{Coverage, FtsQuery, Hit}

  # Standard RRF constant. Dampens the weight of top ranks.
  @rrf_k 60

  # sqlite-vec rejects a `k` above 4096.
  @max_k 4096

  @type result :: %{hits: [Hit.t()], coverage: Coverage.t()}

  @spec search(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, config(:default_limit))
    candidates = limit * config(:candidate_factor)
    min_similarity = Keyword.get(opts, :min_similarity, config(:min_similarity))

    with {:ok, [vector]} <- Embeddings.embed([query], input_type: :query) do
      keyword = keyword_matches(query, candidates)
      semantic = semantic_matches(vector, candidates)

      hits =
        keyword
        |> fuse(semantic)
        |> Enum.filter(&Hit.relevant?(&1, min_similarity))
        |> group_by_document(Keyword.get(opts, :max_passages, config(:max_passages)))
        |> apply_prior(
          Keyword.get(opts, :prior_weight, config(:prior_weight)),
          Keyword.get(opts, :prior_saturation_views, config(:prior_saturation_views))
        )
        |> Enum.take(limit)
        |> load_hits()

      coverage = Coverage.assess(hits, Keyword.put(opts, :limit, limit))
      {:ok, %{hits: hits, coverage: coverage}}
    end
  end

  @doc """
  How many stored documents have a chunk whose cosine similarity to `vector`
  is at least `:min_similarity` (default: the config), at most `:limit`
  (default 10). The vector side of search only: no keywords, no prior, no
  log. The background crawl uses it as "how many pages near this are already
  stored" (#89). It looks at the nearest `:limit * :candidate_factor` chunks
  (at most 4096).
  """
  @spec count_near(Embeddings.vector(), keyword()) :: non_neg_integer()
  def count_near(vector, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_similarity = Keyword.get(opts, :min_similarity, config(:min_similarity))
    k = min(limit * config(:candidate_factor), @max_k)

    %{rows: [[count]]} =
      Repo.query!(
        """
        WITH knn AS MATERIALIZED (
          SELECT rowid, distance FROM chunk_vectors WHERE embedding MATCH ?1 AND k = ?2
        )
        SELECT count(DISTINCT c.document_id) FROM knn
        JOIN chunks AS c ON c.seq = knn.rowid
        WHERE 1.0 - knn.distance >= ?3
        """,
        [{:blob, Vector.encode(vector)}, k, min_similarity]
      )

    min(count, limit)
  end

  # Returns chunk ids in rank order: best `bm25` first (FTS5 scores better
  # matches lower), then by insertion order, so that ties are stable.
  defp keyword_matches(query, limit) do
    case FtsQuery.build(query) do
      nil ->
        []

      match ->
        Repo.query!(
          """
          SELECT c.id FROM chunks_fts
          JOIN chunks AS c ON c.seq = chunks_fts.rowid
          WHERE chunks_fts MATCH ?1
          ORDER BY bm25(chunks_fts), chunks_fts.rowid
          LIMIT ?2
          """,
          [match, limit]
        ).rows
        |> Enum.map(fn [id] -> id end)
    end
  end

  # Returns {chunk_id, cosine_similarity} in rank order. sqlite-vec compares
  # the query with every stored vector (no approximate index), so the list is
  # exact. Equal distances keep insertion order. The KNN query is
  # MATERIALIZED: vec0 accepts no other ORDER BY term than its distance, and
  # SQLite would otherwise merge the outer one into it.
  defp semantic_matches(vector, limit) do
    Repo.query!(
      """
      WITH knn AS MATERIALIZED (
        SELECT rowid, distance FROM chunk_vectors WHERE embedding MATCH ?1 AND k = ?2
      )
      SELECT c.id, 1.0 - knn.distance FROM knn
      JOIN chunks AS c ON c.seq = knn.rowid
      ORDER BY knn.distance, knn.rowid
      """,
      [{:blob, Vector.encode(vector)}, min(limit, @max_k)]
    ).rows
    |> Enum.map(fn [id, similarity] -> {id, similarity} end)
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

  # Adds each chunk's `:document_id`, then groups (see `group/2`).
  defp group_by_document([], _max_passages), do: []

  defp group_by_document(ranked, max_passages) do
    ids = Enum.map(ranked, & &1.chunk_id)

    document_ids =
      Repo.all(from c in Chunk, where: c.id in ^ids, select: {c.id, c.document_id})
      |> Map.new()

    ranked
    |> Enum.filter(&Map.has_key?(document_ids, &1.chunk_id))
    |> Enum.map(&Map.put(&1, :document_id, document_ids[&1.chunk_id]))
    |> group(max_passages)
  end

  # Multiplies each document's score by its prior factor and re-sorts. The
  # sort is stable, so documents with equal scores (for example all of them
  # without a signal) keep the order that fusion gave them.
  defp apply_prior([], _weight, _saturation), do: []
  defp apply_prior(entries, weight, _saturation) when weight == 0, do: entries

  defp apply_prior(entries, weight, saturation) do
    ids = Enum.map(entries, & &1.document_id)

    views =
      Repo.all(
        from d in Document,
          where: d.id in ^ids and not is_nil(d.monthly_views),
          select: {d.id, d.monthly_views}
      )
      |> Map.new()

    entries
    |> Enum.map(fn entry ->
      factor = prior_factor(views[entry.document_id], weight, saturation)
      %{entry | score: entry.score * factor}
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  @doc """
  The factor that the document prior multiplies a document's score by.

  $$factor = 1 + weight \\cdot \\min(1, \\log_{10}(1 + views) / \\log_{10}(1 + saturation))$$

  It is in `1.0..(1 + weight)`, so the prior can lift a document by at most
  `weight` (relative to its score) and never lowers one. A document without a
  signal (`nil`) gets exactly `1.0`. See ADR 0018.
  """
  @spec prior_factor(non_neg_integer() | nil, number(), pos_integer()) :: float()
  def prior_factor(nil, _weight, _saturation), do: 1.0

  def prior_factor(views, weight, saturation) when views >= 0 do
    1.0 + weight * min(1.0, :math.log10(1 + views) / :math.log10(1 + saturation))
  end

  @doc false
  # Turns ranked chunk entries (best first, each with `:document_id`) into one
  # entry per document: the best chunk's entry plus `:passages`, the other
  # chunks best first, at most `max_passages`. Only the best chunk gives the
  # document's score: scores are not summed. Documents are ordered by the
  # position of their best chunk, so equal scores keep the fused order.
  @spec group([map()], non_neg_integer()) :: [map()]
  def group(ranked, max_passages) do
    by_document = Enum.group_by(ranked, & &1.document_id)

    ranked
    |> Enum.uniq_by(& &1.document_id)
    |> Enum.map(fn %{document_id: document_id} ->
      [best | rest] = Map.fetch!(by_document, document_id)
      Map.put(best, :passages, Enum.take(rest, max_passages))
    end)
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
               fetched_at: d.fetched_at,
               source_updated_at: d.source_updated_at,
               license: d.license,
               attribution: d.attribution,
               modified: d.modified,
               share: d.share,
               position: c.position,
               origin: d.origin
             }}
      )
      |> Map.new()

    for entry <- entries, row = rows[entry.chunk_id], row != nil do
      passages =
        for passage <- entry.passages, passage_row = rows[passage.chunk_id], passage_row != nil do
          %{
            chunk_id: passage.chunk_id,
            content: passage_row.content,
            score: passage.score,
            position: passage_row.position
          }
        end

      struct!(Hit, row |> Map.merge(entry) |> Map.put(:passages, passages))
    end
  end

  defp config(key), do: Application.get_env(:knowseek, __MODULE__, []) |> Keyword.fetch!(key)
end
