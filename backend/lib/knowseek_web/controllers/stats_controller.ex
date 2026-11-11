defmodule KnowseekWeb.StatsController do
  use KnowseekWeb, :controller

  alias Knowseek.Activity

  action_fallback KnowseekWeb.FallbackController

  @doc "The numbers over the search log, the pages and the network (#96)."
  def show(conn, _params), do: render(conn, :show, stats: Activity.stats())

  @doc "Deletes every logged search."
  def clear_searches(conn, _params) do
    {:ok, deleted} = Activity.clear_searches()
    render(conn, :cleared, deleted: deleted)
  end
end
