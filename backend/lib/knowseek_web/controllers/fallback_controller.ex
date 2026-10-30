defmodule KnowseekWeb.FallbackController do
  @moduledoc "Translates `{:error, _}` and `nil` results from controllers into JSON errors."
  use KnowseekWeb, :controller

  require Logger

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: KnowseekWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  def call(conn, nil), do: call(conn, {:error, :not_found})

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: KnowseekWeb.ErrorJSON)
    |> render(:"404")
  end

  def call(conn, {:error, {:bad_request, message}}) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: message}})
  end

  def call(conn, {:error, reason}) do
    Logger.error("request failed: #{inspect(reason)}")

    conn
    |> put_status(:internal_server_error)
    |> put_view(json: KnowseekWeb.ErrorJSON)
    |> render(:"500")
  end
end
