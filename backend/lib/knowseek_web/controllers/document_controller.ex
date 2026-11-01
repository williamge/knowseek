defmodule KnowseekWeb.DocumentController do
  use KnowseekWeb, :controller

  alias Knowseek.Documents

  action_fallback KnowseekWeb.FallbackController

  # Ingest embeds the body: limited per client (ADR 0023). Reads are not.
  plug KnowseekWeb.Plugs.RateLimit, [bucket: :documents] when action == :create

  def index(conn, _params) do
    render(conn, :index, documents: Documents.list_documents())
  end

  def show(conn, %{"id" => id}) do
    with %{} = document <- Documents.get_document(id) do
      render(conn, :show, document: document)
    end
  end

  @doc "Manual ingestion, mainly for development and seeding."
  def create(conn, %{"document" => params}) do
    attrs = Map.put(params, "source", "manual")

    with {:ok, document} <- Documents.ingest(attrs) do
      conn
      |> put_status(:created)
      |> render(:show, document: document)
    end
  end

  def create(_conn, _params), do: {:error, {:bad_request, "document is required"}}
end
