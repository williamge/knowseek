defmodule Knowseek.Activity.SearchLog do
  @moduledoc """
  The two writes of the search log. Internal: only `Knowseek.Activity.Recorder`
  calls them, so that no request waits for the write lock (ADR 0031).
  """
  import Ecto.Query

  alias Knowseek.Activity.{SearchHit, SearchRecord}
  alias Knowseek.Repo

  # A search with the same query as one this young is the same search: the
  # web UI repeats a search by itself while discovery runs.
  @same_search_seconds 120

  # How many of the newest rows are checked for a repeat (by rowid, bounded).
  @recent 20

  @doc """
  Stores a search. `record` is what `Knowseek.Activity.record_search/4`
  builds: `:query`, `:coverage`, `:at` and `:hits` (maps with `:rank`,
  `:document_id`, `:positions`, `:background`).

  A repeat of a recent search keeps the row's time and first coverage and
  takes the new hits.
  """
  @spec store(map()) :: {:ok, SearchRecord.t()}
  def store(%{query: query, coverage: coverage, at: at, hits: hits}) do
    Repo.transact(fn ->
      search =
        case repeat(query, at) do
          nil ->
            Repo.insert!(%SearchRecord{query: query, coverage: coverage, inserted_at: at})

          %SearchRecord{} = found ->
            Repo.delete_all(from h in SearchHit, where: h.search_id == ^found.id)
            found
        end

      Repo.insert_all(SearchHit, Enum.map(hits, &Map.put(&1, :search_id, search.id)))
      {:ok, search}
    end)
  end

  @doc "Deletes every search; its hits go with it (cascade). Returns the number of searches."
  @spec clear() :: {:ok, non_neg_integer()}
  def clear do
    {count, _} = Repo.delete_all(SearchRecord)
    {:ok, count}
  end

  defp repeat(query, at) do
    oldest = DateTime.add(at, -@same_search_seconds, :second)

    Repo.all(from s in SearchRecord, order_by: [desc: s.id], limit: @recent)
    |> Enum.find(&(&1.query == query and DateTime.compare(&1.inserted_at, oldest) != :lt))
  end
end
