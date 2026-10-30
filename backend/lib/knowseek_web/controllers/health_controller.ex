defmodule KnowseekWeb.HealthController do
  use KnowseekWeb, :controller

  alias Ecto.Adapters.SQL

  def show(conn, _params) do
    case SQL.query(Knowseek.Repo, "SELECT 1", []) do
      {:ok, _} ->
        json(conn, %{status: "ok", database: "ok"})

      {:error, _} ->
        conn |> put_status(:service_unavailable) |> json(%{status: "error", database: "error"})
    end
  end
end
