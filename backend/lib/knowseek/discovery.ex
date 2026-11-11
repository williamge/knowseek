defmodule Knowseek.Discovery do
  @moduledoc """
  Seeks new data for a query when the index does not cover it.

  `request/1` enqueues a `Knowseek.Discovery.SeekWorker` job. The job calls
  `run/2`, which asks every configured `Knowseek.Discovery.Source` for
  candidates and ingests them.

  Requests for the same normalized query within one hour are deduplicated.
  The insert runs in a transaction: Oban's SQLite engine checks uniqueness
  and inserts in two statements, and only the transaction's write lock
  (taken up front, ADR 0030) keeps two requests from both inserting.

  Each ingested candidate carries its origin (#96, ADR 0031): `origin:
  "search"` and the normalized query as `origin_query`. A source never sets
  them. The bytes a source downloads are counted in memory while it runs (the
  `:on_bytes` option of `Knowseek.Discovery.Source.discover/2`) and recorded
  with `Knowseek.Activity.record_bytes/2` after it returned, also when it
  failed.
  """
  require Logger

  alias Knowseek.Activity
  alias Knowseek.Discovery.SeekWorker
  alias Knowseek.Documents
  alias Knowseek.Repo

  @type summary :: %{ingested: non_neg_integer(), failed: non_neg_integer()}

  @spec request(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def request(query) when is_binary(query) do
    job = SeekWorker.new(%{"query" => normalize(query)})
    Repo.transact(fn -> Oban.insert(job) end)
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

  # A query longer than this is cut in `documents.origin_query`.
  @max_origin_query 500

  defp discover(source, query, opts) do
    result =
      counting_bytes(source, fn on_bytes ->
        source.discover(query, Keyword.put(opts, :on_bytes, on_bytes))
      end)

    case result do
      {:ok, candidates} ->
        # Search-time discovery is the only caller today; #89 adds "background".
        origin = %{
          source: source.name(),
          origin: "search",
          origin_query: String.slice(query, 0, @max_origin_query)
        }

        Enum.map(candidates, &Map.merge(&1, origin))

      {:error, reason} ->
        Logger.warning("discovery source #{inspect(source)} failed: #{inspect(reason)}")
        []
    end
  end

  # Runs `fun` with a function that counts downloaded bytes, then records the
  # total for `source`: one write, after the external calls (rules 3 and 5).
  defp counting_bytes(source, fun) do
    counter = :counters.new(1, [])
    result = fun.(fn bytes -> :counters.add(counter, 1, bytes) end)
    Activity.record_bytes(source.name(), :counters.get(counter, 1))
    result
  end
end
