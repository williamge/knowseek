defmodule Knowseek.Discovery.Planner.Passthrough do
  @moduledoc """
  Planner that plans nothing: the search query is the user's query, as before
  query planning existed. The default adapter, and the one tests pin.
  """
  @behaviour Knowseek.Discovery.Planner

  @impl true
  def plan(query, _opts), do: {:ok, [query]}
end
