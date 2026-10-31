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

  # The embedding provider (Ollama, Voyage) is down or timed out. There is no
  # fallback to another adapter (ADR 0016), so the caller gets a 503, not a 500.
  def call(conn, {:error, {provider, _reason} = reason}) when provider in [:ollama, :voyage] do
    Logger.error("embedding provider unavailable: #{inspect(reason)}")

    conn
    |> put_status(:service_unavailable)
    |> json(%{errors: %{detail: "Embedding provider unavailable (#{provider})"}})
  end

  def call(conn, {:error, reason}) do
    Logger.error("request failed: #{inspect(reason)}")

    conn
    |> put_status(:internal_server_error)
    |> put_view(json: KnowseekWeb.ErrorJSON)
    |> render(:"500")
  end
end
