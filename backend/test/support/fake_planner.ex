defmodule Knowseek.Discovery.FakePlanner do
  @moduledoc """
  A planner for tests. Returns what the test put in the process dictionary
  with `FakePlanner.put/1` (the planner runs in the calling process): a list of
  queries, `{:error, reason}`, or `:raise`. Records the queries it was asked in
  the `{:fake_planner_asked, query}` message sent to the test process.
  """
  @behaviour Knowseek.Discovery.Planner

  @doc "Sets what the next `plan/2` calls return: a list, `{:error, reason}`, or `:raise`."
  def put(result), do: Process.put(__MODULE__, result)

  @impl true
  def plan(query, _opts) do
    send(self(), {:fake_planner_asked, query})

    case Process.get(__MODULE__, []) do
      :raise -> raise "planner crashed"
      {:error, _reason} = error -> error
      queries when is_list(queries) -> {:ok, queries}
      other -> other
    end
  end
end
