defmodule KnowseekWeb.SearchController do
  use KnowseekWeb, :controller

  alias Knowseek.Lookup

  action_fallback KnowseekWeb.FallbackController

  @max_limit 50
  # About 68 years. Keeps DateTime arithmetic in range.
  @max_age_seconds 2_147_483_647

  def create(conn, %{"query" => query} = params) when is_binary(query) do
    with {:ok, query} <- parse_query(query),
         {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, max_age} <- parse_max_age(params),
         {:ok, result} <- Lookup.run(query, [limit: limit] ++ max_age) do
      render(conn, :show, result: result)
    end
  end

  def create(_conn, _params), do: {:error, {:bad_request, "query is required"}}

  defp parse_query(query) do
    case String.trim(query) do
      "" -> {:error, {:bad_request, "query is required"}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp parse_limit(nil),
    do: {:ok, Application.get_env(:knowseek, Knowseek.Search)[:default_limit]}

  defp parse_limit(n) when is_integer(n) and n in 1..@max_limit, do: {:ok, n}

  defp parse_limit(_),
    do: {:error, {:bad_request, "limit must be an integer from 1 to #{@max_limit}"}}

  # Absent: Coverage uses the configured default. `null`: ignore age.
  defp parse_max_age(params) do
    case Map.fetch(params, "max_age_seconds") do
      :error ->
        {:ok, []}

      {:ok, n} when is_nil(n) or (is_integer(n) and n in 1..@max_age_seconds//1) ->
        {:ok, [max_age_seconds: n]}

      {:ok, _} ->
        {:error,
         {:bad_request,
          "max_age_seconds must be null or an integer from 1 to #{@max_age_seconds}"}}
    end
  end
end
