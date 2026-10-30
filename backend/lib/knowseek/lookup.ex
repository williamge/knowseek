defmodule Knowseek.Lookup do
  @moduledoc """
  The main entry point: answer a query from the index, and seek new data
  when the index does not cover it well enough.

      {:ok, result} = Knowseek.Lookup.run("rust async runtimes")
      result.coverage   #=> :partial
      result.discovery  #=> {:enqueued, job_id}

  Results from discovery arrive later. A caller can query again, or (a
  future task) subscribe to updates for the query.
  """

  alias Knowseek.{Discovery, Search}

  @type discovery :: :not_needed | {:enqueued, pos_integer()} | {:error, term()}

  @type result :: %{
          query: String.t(),
          hits: [Search.Hit.t()],
          coverage: Search.Coverage.t(),
          discovery: discovery()
        }

  @spec run(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(query, opts \\ []) do
    with {:ok, %{hits: hits, coverage: coverage}} <- Search.search(query, opts) do
      {:ok, %{query: query, hits: hits, coverage: coverage, discovery: discover(query, coverage)}}
    end
  end

  defp discover(_query, :sufficient), do: :not_needed

  defp discover(query, _coverage) do
    case Discovery.request(query) do
      {:ok, job} -> {:enqueued, job.id}
      {:error, reason} -> {:error, reason}
    end
  end
end
