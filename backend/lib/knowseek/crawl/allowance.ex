defmodule Knowseek.Crawl.Allowance do
  @moduledoc """
  How far each search pulls the crawl (#89, ADR 0033): earned depth. Pure.

  A page earns link-fetches each time it is in the logged results of a
  search: `earn_single` as the only result, `earn_top` in the first
  `top_ranks`, `earn_rest` lower. The earnings expire with the window. The
  functions take the `Knowseek.Crawl` config as a keyword list.
  """

  @type source :: %{
          document_id: Ecto.UUID.t(),
          earned: pos_integer(),
          gap: boolean(),
          shown: pos_integer(),
          last_at: DateTime.t(),
          queries: [String.t()]
        }

  @doc """
  What the appearances of one page earn: `earn_single` as a search's only
  result, else `earn_top` at rank `top_ranks` or better, else `earn_rest`.
  """
  @spec earned([Knowseek.Activity.appearance()], keyword()) :: non_neg_integer()
  def earned(appearances, config) do
    top_ranks = config[:top_ranks]

    appearances
    |> Enum.map(fn
      %{single: true} -> config[:earn_single]
      %{rank: rank} when rank <= top_ranks -> config[:earn_top]
      _lower -> config[:earn_rest]
    end)
    |> Enum.sum()
  end

  @doc """
  The source pages from `Knowseek.Activity.result_pages/1`, in the order they
  are read: pages that were a search's only result first, then most shown,
  then most recently shown, then by id. `queries` are the distinct queries
  that showed the page, newest first, at most `max_queries`.
  """
  @spec sources(%{Ecto.UUID.t() => [Knowseek.Activity.appearance()]}, keyword()) :: [source()]
  def sources(pages, config) do
    pages
    |> Enum.map(fn {document_id, appearances} -> source(document_id, appearances, config) end)
    |> Enum.sort_by(fn source ->
      {not source.gap, -source.shown, -DateTime.to_unix(source.last_at), source.document_id}
    end)
  end

  defp source(document_id, appearances, config) do
    newest_first = Enum.sort_by(appearances, & &1.at, {:desc, DateTime})

    %{
      document_id: document_id,
      earned: earned(appearances, config),
      gap: Enum.any?(appearances, & &1.single),
      shown: length(appearances),
      last_at: hd(newest_first).at,
      queries:
        newest_first
        |> Enum.map(& &1.query)
        |> Enum.uniq()
        |> Enum.take(config[:max_queries])
    }
  end
end
