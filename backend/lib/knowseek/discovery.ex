defmodule Knowseek.Discovery do
  @moduledoc """
  Seeks new data for a query when the index does not cover it.

  `request/1` enqueues a `Knowseek.Discovery.SeekWorker` job. The job calls
  `run/2`, which asks the planner (`Knowseek.Discovery.Planner`) for search
  queries, asks every configured `Knowseek.Discovery.Source` for candidates
  for each of them, and ingests the candidates. The planner runs here, in the
  job, never in the request path.

  The original query is always searched first. Candidates are merged, with
  one candidate per canonical URL, in rounds: the first candidate of every
  query, then the second of every query, and so on, so the original query
  keeps its place when the cap bites. At most `max_candidates` are ingested
  (config, 12 by default). A source that fails for one query costs only that
  query's candidates.

  Requests for the same normalized query within one hour are deduplicated.
  The plan is not part of a job's arguments, so a retried job plans again.
  """
  require Logger

  alias Knowseek.Discovery.{Planner, SeekWorker}
  alias Knowseek.Documents
  alias Knowseek.Documents.URL

  @default_max_candidates 12

  @typedoc """
  `plan` is the list of queries searched, the original first. `planner` is
  `:passthrough` (nothing planned), `:ok`, or `{:fallback, reason}` (the
  planner failed, only the original was searched).
  """
  @type summary :: %{
          ingested: non_neg_integer(),
          failed: non_neg_integer(),
          plan: [String.t(), ...],
          planner: Planner.status()
        }

  @spec request(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def request(query) when is_binary(query) do
    %{"query" => normalize(query)}
    |> SeekWorker.new()
    |> Oban.insert()
  end

  @doc """
  Plans `query`, runs every source for every planned query, and ingests the
  results.

  Options: `:sources` (modules, default the configured ones), `:planner` (a
  `Knowseek.Discovery.Planner` module, default the configured one),
  `:max_candidates` (default the configured one). The options also go to
  every source.
  """
  @spec run(String.t(), keyword()) :: {:ok, summary()}
  def run(query, opts \\ []) do
    sources = Keyword.get(opts, :sources, sources())
    max_candidates = Keyword.get(opts, :max_candidates, max_candidates())
    %{queries: queries, status: status} = Planner.resolve(query, opts)

    Logger.info(
      "discovery plan for #{inspect(query)}: #{inspect(queries)} (planner: #{inspect(status)})"
    )

    counts =
      queries
      |> candidate_lists(sources, opts)
      |> merge()
      |> Enum.take(max_candidates)
      |> Enum.reduce(%{ingested: 0, failed: 0}, fn attrs, acc ->
        case Documents.ingest(attrs) do
          {:ok, _document} ->
            Map.update!(acc, :ingested, &(&1 + 1))

          {:error, reason} ->
            Logger.warning("discovery ingest failed: #{inspect(reason)}")
            Map.update!(acc, :failed, &(&1 + 1))
        end
      end)

    {:ok, Map.merge(counts, %{plan: queries, planner: status})}
  end

  @spec sources() :: [module()]
  def sources, do: config() |> Keyword.get(:sources, [])

  @doc "The most candidates one run ingests."
  @spec max_candidates() :: pos_integer()
  def max_candidates, do: config() |> Keyword.get(:max_candidates, @default_max_candidates)

  @doc "Lowercases and collapses whitespace so equivalent queries share one job."
  @spec normalize(String.t()) :: String.t()
  def normalize(query), do: query |> String.downcase() |> String.split() |> Enum.join(" ")

  defp config, do: Application.get_env(:knowseek, __MODULE__, [])

  # One candidate list per (query, source), the original query's first and,
  # within a query, in the order of the sources. A source that can find the
  # documents of all the queries together (`discover_many/2`) is asked once.
  defp candidate_lists(queries, sources, opts) do
    by_source = Enum.map(sources, &discover(&1, queries, opts))

    Enum.flat_map(0..(length(queries) - 1)//1, fn index ->
      Enum.map(by_source, &Enum.at(&1, index))
    end)
  end

  defp discover(source, queries, opts) do
    results =
      if Code.ensure_loaded?(source) and function_exported?(source, :discover_many, 2) do
        source.discover_many(queries, opts)
      else
        Enum.map(queries, &source.discover(&1, opts))
      end

    queries
    |> Enum.zip(results)
    |> Enum.map(fn
      {_query, {:ok, candidates}} ->
        Enum.map(candidates, &Map.put(&1, :source, source.name()))

      {query, {:error, reason}} ->
        Logger.warning(
          "discovery source #{inspect(source)} failed for #{inspect(query)}: #{inspect(reason)}"
        )

        []
    end)
  end

  # Interleaves the candidate lists (one per planned query and source, the
  # original query first) and keeps the first candidate of every canonical URL.
  defp merge(lists) do
    lists
    |> interleave()
    |> Enum.uniq_by(&dedupe_key/1)
  end

  defp interleave(lists) do
    case Enum.reject(lists, &(&1 == [])) do
      [] -> []
      lists -> Enum.map(lists, &hd/1) ++ interleave(Enum.map(lists, &tl/1))
    end
  end

  # A candidate without a usable URL is never merged into another one.
  defp dedupe_key(%{url: url}) when is_binary(url), do: URL.canonicalize(url)
  defp dedupe_key(_candidate), do: {:no_url, make_ref()}
end
