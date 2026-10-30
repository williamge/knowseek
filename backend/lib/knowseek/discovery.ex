defmodule Knowseek.Discovery do
  @moduledoc """
  Seeks new data for a query when the index does not cover it.

  `request/1` enqueues a `Knowseek.Discovery.SeekWorker` job. The job calls
  `run/2`, which asks every configured `Knowseek.Discovery.Source` for
  candidates and ingests them.

  Requests for the same normalized query within one hour are deduplicated.
  """
  require Logger

  alias Knowseek.Discovery.SeekWorker
  alias Knowseek.Documents

  @type summary :: %{ingested: non_neg_integer(), failed: non_neg_integer()}

  @spec request(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def request(query) when is_binary(query) do
    %{"query" => normalize(query)}
    |> SeekWorker.new()
    |> Oban.insert()
  end

  @doc "Runs every source for `query` and ingests the results."
  @spec run(String.t(), keyword()) :: {:ok, summary()}
  def run(query, opts \\ []) do
    sources = Keyword.get(opts, :sources, sources())

    summary =
      sources
      |> Enum.flat_map(&discover(&1, query, opts))
      |> Enum.reduce(%{ingested: 0, failed: 0}, fn attrs, acc ->
        case Documents.ingest(attrs) do
          {:ok, _document} ->
            Map.update!(acc, :ingested, &(&1 + 1))

          {:error, reason} ->
            Logger.warning("discovery ingest failed: #{inspect(reason)}")
            Map.update!(acc, :failed, &(&1 + 1))
        end
      end)

    {:ok, summary}
  end

  @spec sources() :: [module()]
  def sources, do: Application.get_env(:knowseek, __MODULE__, []) |> Keyword.get(:sources, [])

  @doc "Lowercases and collapses whitespace so equivalent queries share one job."
  @spec normalize(String.t()) :: String.t()
  def normalize(query), do: query |> String.downcase() |> String.split() |> Enum.join(" ")

  defp discover(source, query, opts) do
    case source.discover(query, opts) do
      {:ok, candidates} ->
        Enum.map(candidates, &Map.put(&1, :source, source.name()))

      {:error, reason} ->
        Logger.warning("discovery source #{inspect(source)} failed: #{inspect(reason)}")
        []
    end
  end
end
