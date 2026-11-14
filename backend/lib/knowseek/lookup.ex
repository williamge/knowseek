defmodule Knowseek.Lookup do
  @moduledoc """
  The main entry point: answer a query from the index, and seek new data
  when the index does not cover it well enough.

      {:ok, result} = Knowseek.Lookup.run("rust async runtimes")
      result.coverage   #=> :partial
      result.discovery  #=> {:enqueued, job_id}

  Results from discovery arrive later. A caller can query again, or (a
  future task) subscribe to updates for the query. When a budget is used up
  (#90, ADR 0034) nothing is enqueued and `discovery` is `{:refused,
  :disk | :network}`; the hits come from the index as always.

  Every successful run is handed to `Knowseek.Activity.record_search/4`, which
  only sends a message to the log's writer (rule 6, ADR 0031). `Search.search/2`
  called directly logs nothing; a failed search logs nothing.
  """

  alias Knowseek.{Activity, Discovery, Documents, Search}

  @type discovery ::
          :not_needed
          | {:enqueued, pos_integer()}
          | {:refused, Knowseek.Activity.hold()}
          | {:error, term()}

  # `reembedding` is nil, or how many passages have the configured embedding
  # model's vectors out of all, while pages are being embedded again after a
  # change of model (#84): older pages are then found by keyword only.
  @type result :: %{
          query: String.t(),
          hits: [Search.Hit.t()],
          coverage: Search.Coverage.t(),
          discovery: discovery(),
          reembedding: %{done: non_neg_integer(), total: non_neg_integer()} | nil
        }

  @spec run(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(query, opts \\ []) do
    with {:ok, %{hits: hits, coverage: coverage}} <- Search.search(query, opts) do
      # Off the request path: a message to the recorder, no database write here
      # (rule 6, ADR 0031).
      :ok = Activity.record_search(Discovery.normalize(query), coverage, hits)

      {:ok,
       %{
         query: query,
         hits: hits,
         coverage: coverage,
         discovery: discover(query, coverage),
         reembedding: Documents.reembed_progress()
       }}
    end
  end

  defp discover(_query, :sufficient), do: :not_needed

  defp discover(query, _coverage) do
    case Discovery.request(query) do
      {:ok, job} -> {:enqueued, job.id}
      {:error, {:budget, reason}} -> {:refused, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
