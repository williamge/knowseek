defmodule Knowseek.Discovery.BatchSource do
  @moduledoc """
  A discovery source for tests that implements `discover_many/2`, with a result
  per query like `ScriptedSource` (`BatchSource.put/1`, a map of query to
  `{:ok, candidates}` or `{:error, reason}`). It sends the test process
  `{:batch_source_asked, queries}` once per `discover_many/2` call. `discover/2`
  is a failure: discovery must use the batch callback.
  """
  @behaviour Knowseek.Discovery.Source

  @doc "Sets the results, a map of query to `{:ok, candidates}` or `{:error, reason}`."
  def put(results), do: Process.put(__MODULE__, results)

  @impl true
  def name, do: "batch"

  @impl true
  def discover(_query, _opts), do: raise("discovery must call discover_many/2")

  @impl true
  def discover_many(queries, _opts) do
    send(self(), {:batch_source_asked, queries})
    results = Process.get(__MODULE__, %{})
    Enum.map(queries, &Map.get(results, &1, {:ok, []}))
  end
end
