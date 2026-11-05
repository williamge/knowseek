defmodule Knowseek.Discovery.ModelPlanner do
  @moduledoc """
  A planner for the playground tests whose answer depends on the model in the
  options (the playground runs the planner in a task, so a process dictionary
  would not reach it). Models: `"good"` plans `["rock pool", "intertidal"]`,
  `"other"` plans `["tide"]`, `"bad"` returns an error, `"crash"` raises,
  `"slow"` takes a second, anything else plans its own name. Every call is sent
  to the process in `ModelPlanner.notify/1` as `{:model_planner, query, opts}`.
  """
  @behaviour Knowseek.Discovery.Planner

  @doc "Sends the calls to `pid`."
  def notify(pid), do: Application.put_env(:knowseek, __MODULE__, notify: pid)

  @impl true
  def plan(query, opts) do
    if pid = Application.get_env(:knowseek, __MODULE__, [])[:notify],
      do: send(pid, {:model_planner, query, opts})

    case opts[:model] do
      "good" ->
        {:ok, ["rock pool", "intertidal"]}

      "other" ->
        {:ok, ["tide"]}

      "bad" ->
        {:error, :model_missing}

      "crash" ->
        raise "model crashed"

      "slow" ->
        Process.sleep(1_000)
        {:ok, ["too late"]}

      model ->
        {:ok, [model]}
    end
  end
end
