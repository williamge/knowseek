defmodule Knowseek.Search.Coverage do
  @moduledoc """
  Decides whether the index covers a query well enough, or whether the
  service should seek new data.

  A hit is "strong" if it matched the full-text search, or if its cosine
  similarity is at least `:min_similarity`. The result is:

    * `:sufficient` - at least `:min_strong_hits` strong hits
    * `:partial` - at least one strong hit
    * `:none` - no strong hits

  This is a placeholder heuristic. It ignores freshness and does not check
  that the hits actually answer the query.
  """

  alias Knowseek.Search.Hit

  @type t :: :sufficient | :partial | :none

  @spec assess([Hit.t()], keyword()) :: t()
  def assess(hits, opts \\ []) do
    config = Application.get_env(:knowseek, Knowseek.Search, [])
    min_similarity = Keyword.get(opts, :min_similarity, config[:min_similarity])
    min_strong_hits = Keyword.get(opts, :min_strong_hits, config[:min_strong_hits])

    strong = Enum.count(hits, &strong?(&1, min_similarity))

    cond do
      strong >= min_strong_hits -> :sufficient
      strong > 0 -> :partial
      true -> :none
    end
  end

  defp strong?(%Hit{keyword_rank: rank}, _min_similarity) when is_integer(rank), do: true
  defp strong?(%Hit{similarity: nil}, _min_similarity), do: false
  defp strong?(%Hit{similarity: similarity}, min_similarity), do: similarity >= min_similarity
end
