defmodule KnowseekWeb.PlannerPlaygroundController do
  @moduledoc """
  The planner playground API (ADR 0025). **Dev only**: `KnowseekWeb.Router`
  mounts it only when `:dev_routes` is true, so it does not exist in test or in
  a release. It calls Ollama in the request path, an exception to AGENTS.md
  rule 6 that only holds because of that, and it is read-only: nothing is
  ingested. The logic is in `Knowseek.Discovery.Playground`.

    * `GET /api/planner/models` - the installed chat models and the default
    * `POST /api/planner/preview` - `{query, models: [string], source: bool}`.
      At most `Playground.max_models/0` models, run one after another.
  """
  use KnowseekWeb, :controller

  alias Knowseek.Discovery.Playground

  @max_model_name_length 100

  def models(conn, _params) do
    case Playground.models() do
      {:ok, data} -> json(conn, %{data: data})
      {:error, detail} -> conn |> put_status(:service_unavailable) |> error(detail)
    end
  end

  def preview(conn, params) do
    with {:ok, query} <- parse_query(params["query"]),
         {:ok, models} <- parse_models(params["models"]),
         {:ok, source?} <- parse_source(params["source"]) do
      json(conn, %{data: Playground.preview(query, models, source: source?)})
    else
      {:error, detail} -> conn |> put_status(:bad_request) |> error(detail)
    end
  end

  defp error(conn, detail), do: json(conn, %{errors: %{detail: detail}})

  defp parse_query(query) when is_binary(query) do
    case String.trim(query) do
      "" ->
        {:error, "query is required"}

      trimmed ->
        if String.length(trimmed) <= Playground.max_query_length(),
          do: {:ok, trimmed},
          else: {:error, "query is at most #{Playground.max_query_length()} characters"}
    end
  end

  defp parse_query(_query), do: {:error, "query is required"}

  # Absent: the configured model.
  defp parse_models(nil), do: {:ok, [Playground.default_model()]}

  defp parse_models(models) when is_list(models) do
    names = models |> Enum.map(&clean_name/1) |> Enum.uniq()

    cond do
      names == [] or nil in names ->
        {:error, "models must be a list of model names"}

      length(names) > Playground.max_models() ->
        {:error, "at most #{Playground.max_models()} models at a time"}

      true ->
        {:ok, names}
    end
  end

  defp parse_models(_models), do: {:error, "models must be a list of model names"}

  defp clean_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed when byte_size(trimmed) <= @max_model_name_length -> trimmed
      _too_long -> nil
    end
  end

  defp clean_name(_name), do: nil

  defp parse_source(nil), do: {:ok, true}
  defp parse_source(source) when is_boolean(source), do: {:ok, source}
  defp parse_source(_source), do: {:error, "source must be true or false"}
end
