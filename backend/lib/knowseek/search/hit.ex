defmodule Knowseek.Search.Hit do
  @moduledoc """
  One search result: a document, shown by its best matching chunk.

  `chunk_id`, `content`, `score`, `keyword_rank`, `semantic_rank`, and
  `similarity` describe the document's best chunk. The document's other
  matching chunks are in `passages`.

    * `score` - the fused (reciprocal rank fusion) score of the best chunk.
      Higher is better. It is not a sum over the document's chunks.
    * `passages` - other relevant chunks of the same document, best first,
      at most `:max_passages` (see `Knowseek.Search`). Each has `:chunk_id`,
      `:content`, and `:score`. Empty when only one chunk matched.
    * `keyword_rank` - 1-based rank in the full-text results, or `nil`.
    * `semantic_rank` - 1-based rank in the vector results, or `nil`.
    * `similarity` - cosine similarity to the query (-1.0 to 1.0), or `nil`.

  A hit is relevant when it matched the full-text search, or when its
  similarity is at least `min_similarity`. See `relevant?/2`.
  """

  @type passage :: %{chunk_id: Ecto.UUID.t(), content: String.t(), score: float()}

  @type t :: %__MODULE__{
          chunk_id: Ecto.UUID.t(),
          document_id: Ecto.UUID.t(),
          url: String.t(),
          title: String.t() | nil,
          content: String.t(),
          published_at: DateTime.t() | nil,
          fetched_at: DateTime.t(),
          score: float(),
          keyword_rank: pos_integer() | nil,
          semantic_rank: pos_integer() | nil,
          similarity: float() | nil,
          passages: [passage()]
        }

  defstruct [
    :chunk_id,
    :document_id,
    :url,
    :title,
    :content,
    :published_at,
    :fetched_at,
    :score,
    :keyword_rank,
    :semantic_rank,
    :similarity,
    passages: []
  ]

  @doc """
  Whether a hit is relevant to the query.

  The vector search always returns the nearest chunks, however far away
  they are. This rule tells a real match from the least bad one. It accepts
  a `t:t/0` or any map with `:keyword_rank` and `:similarity`.
  """
  @spec relevant?(%{keyword_rank: term(), similarity: term()}, float()) :: boolean()
  def relevant?(%{keyword_rank: rank}, _min_similarity) when is_integer(rank), do: true
  def relevant?(%{similarity: nil}, _min_similarity), do: false
  def relevant?(%{similarity: similarity}, min_similarity), do: similarity >= min_similarity
end
