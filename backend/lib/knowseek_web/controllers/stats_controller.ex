defmodule KnowseekWeb.StatsController do
  use KnowseekWeb, :controller

  alias Knowseek.{Activity, Crawl}

  action_fallback KnowseekWeb.FallbackController

  @doc "The numbers over the search log, the pages, the network (#96) and the crawl (#89)."
  def show(conn, _params), do: render(conn, :show, stats: Activity.stats(), crawl: Crawl.stats())

  @doc "Deletes every logged search, and the crawl's link lists and pending candidates derived from them."
  def clear_searches(conn, _params) do
    {:ok, deleted} = Activity.clear_searches()
    {:ok, _candidates} = Crawl.clear_pending()
    render(conn, :cleared, deleted: deleted)
  end
end
