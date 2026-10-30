defmodule Knowseek.Search.Coverage do
  @moduledoc """
  Decides whether the index covers a query well enough, or whether the
  service should seek new data.

  A hit is "strong" when it is both relevant and fresh:

    * relevant - see `Knowseek.Search.Hit.relevant?/2`: it matched the
      full-text search, or its cosine similarity is at least `:min_similarity`
    * fresh - `:max_age_seconds` is `nil`, or the document's `fetched_at`
      is between `:max_age_seconds` ago and now. `fetched_at` is the last
      time a fetch saw the content, so a re-fetch makes a document fresh
      again. A `fetched_at` in the future is bad data and is not fresh.

  Strong hits are counted per document: many strong chunks of one document
  count once. The result is:

    * `:sufficient` - at least `:min_strong_hits` documents with a strong hit
    * `:partial` - at least one document with a strong hit
    * `:none` - no strong hits

  When the caller asks for fewer hits than `:min_strong_hits` (the `:limit`
  option), the threshold is lowered to `:limit`, so a small result set can
  still be `:sufficient`.

  `assess/2` is a pure function of the hits and the options. Options that
  are not given come from the `Knowseek.Search` config, and `:now` defaults
  to the current time.

  This is a placeholder heuristic. It does not check that the hits actually
  answer the query.
  """

  alias Knowseek.Search.Hit

  @type t :: :sufficient | :partial | :none

  @spec assess([Hit.t()], keyword()) :: t()
  def assess(hits, opts \\ []) do
    config = Application.get_env(:knowseek, Knowseek.Search, [])
    min_similarity = Keyword.get(opts, :min_similarity, config[:min_similarity])
    min_strong_hits = Keyword.get(opts, :min_strong_hits, config[:min_strong_hits])
    min_strong_hits = min(min_strong_hits, Keyword.get(opts, :limit, min_strong_hits))
    max_age_seconds = Keyword.get(opts, :max_age_seconds, config[:max_age_seconds])
    window = window(max_age_seconds, Keyword.get_lazy(opts, :now, &DateTime.utc_now/0))

    strong =
      hits
      |> Enum.filter(&(Hit.relevant?(&1, min_similarity) and fresh?(&1, window)))
      |> Enum.uniq_by(& &1.document_id)
      |> length()

    cond do
      strong >= min_strong_hits -> :sufficient
      strong > 0 -> :partial
      true -> :none
    end
  end

  defp window(nil, _now), do: nil
  defp window(max_age_seconds, now), do: {DateTime.add(now, -max_age_seconds, :second), now}

  defp fresh?(_hit, nil), do: true

  defp fresh?(%Hit{fetched_at: fetched_at}, {from, to}),
    do: DateTime.compare(fetched_at, from) != :lt and DateTime.compare(fetched_at, to) != :gt
end
