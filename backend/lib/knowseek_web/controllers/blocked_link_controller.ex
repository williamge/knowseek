defmodule KnowseekWeb.BlockedLinkController do
  use KnowseekWeb, :controller

  alias Knowseek.Discovery

  action_fallback KnowseekWeb.FallbackController

  @doc "The blocked-link log by domain (#88)."
  def index(conn, _params) do
    render(conn, :index,
      log: Discovery.blocked_domains(),
      allowed_hosts: Discovery.allowed_hosts()
    )
  end

  @doc "Starts the link backfill. Only enqueues; the jobs run in the background."
  def backfill(conn, _params) do
    with {:ok, enqueued} <- Discovery.backfill_links() do
      conn
      |> put_status(:accepted)
      |> render(:backfill, enqueued: enqueued)
    end
  end
end
