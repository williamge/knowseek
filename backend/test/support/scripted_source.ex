defmodule Knowseek.Discovery.ScriptedSource do
  @moduledoc """
  A discovery source for tests with a result per query. The test puts a map
  from query to `{:ok, candidates}` or `{:error, reason}` into the process
  dictionary with `ScriptedSource.put/1`; a query that is not in the map finds
  nothing. Every query it is asked is sent to the test process as
  `{:scripted_source_asked, query}`.
  """
  @behaviour Knowseek.Discovery.Source

  @doc "Sets the results, a map of query to `{:ok, candidates}` or `{:error, reason}`."
  def put(results), do: Process.put(__MODULE__, results)

  @doc "A candidate with a body that is long enough to ingest."
  def candidate(url, title \\ nil) do
    %{url: url, title: title || url, body: "This document is about #{title || url}."}
  end

  @impl true
  def name, do: "scripted"

  @impl true
  def discover(query, _opts) do
    send(self(), {:scripted_source_asked, query})
    Process.get(__MODULE__, %{}) |> Map.get(query, {:ok, []})
  end
end
