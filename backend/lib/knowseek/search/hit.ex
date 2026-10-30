defmodule Knowseek.Search.Hit do
  @moduledoc """
  One search result: a matching chunk plus its parent document's metadata.

    * `score` - the fused (reciprocal rank fusion) score. Higher is better.
    * `keyword_rank` - 1-based rank in the full-text results, or `nil`.
    * `semantic_rank` - 1-based rank in the vector results, or `nil`.
    * `similarity` - cosine similarity to the query (-1.0 to 1.0), or `nil`.
  """

  @type t :: %__MODULE__{
          chunk_id: Ecto.UUID.t(),
          document_id: Ecto.UUID.t(),
          url: String.t(),
          title: String.t() | nil,
          content: String.t(),
          fetched_at: DateTime.t(),
          score: float(),
          keyword_rank: pos_integer() | nil,
          semantic_rank: pos_integer() | nil,
          similarity: float() | nil
        }

  defstruct [
    :chunk_id,
    :document_id,
    :url,
    :title,
    :content,
    :fetched_at,
    :score,
    :keyword_rank,
    :semantic_rank,
    :similarity
  ]
end
