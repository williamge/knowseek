defmodule KnowseekWeb.CrawlController do
  use KnowseekWeb, :controller

  alias Knowseek.Crawl

  action_fallback KnowseekWeb.FallbackController

  @doc "What the background crawl would do next: the scored links in fetch order (#89)."
  def show(conn, _params), do: render(conn, :show, overview: Crawl.overview())
end
