defmodule Knowseek.Activity.Recorder do
  @moduledoc """
  The in-process writer of the search log (#96, ADR 0031): a supervised
  `GenServer` with no state, one per node, registered under its module name.

  A search request sends it one message (`Knowseek.Activity.record_search/4`)
  and returns. The request never takes SQLite's write lock for the log, so it
  never waits behind an ingest. This is the second named in-process exception
  to rule 6 in `AGENTS.md`, next to `Knowseek.Cache`.

  The log is best effort: a search handed over just before the node stops can
  be lost, and a row is dropped when the write fails (for example when the
  write lock stays busy past the 5 s `busy_timeout`).
  """
  use GenServer

  require Logger

  alias Knowseek.Activity.SearchLog

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(:ok), do: {:ok, :no_state}

  @impl true
  def handle_cast({:search, record}, state) do
    try do
      {:ok, _search} = SearchLog.store(record)
    rescue
      # The one place a broad `rescue` is right: this writer must never
      # crash-loop. Three crashes in five seconds would stop the application's
      # supervisor, and a log row is not worth that. The row is dropped.
      error -> Logger.warning("search not logged: #{Exception.message(error)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:clear, _from, state), do: {:reply, SearchLog.clear(), state}
end
