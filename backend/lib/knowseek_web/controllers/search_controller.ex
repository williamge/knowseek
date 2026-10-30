defmodule KnowseekWeb.SearchController do
  use KnowseekWeb, :controller

  alias Knowseek.Lookup

  action_fallback KnowseekWeb.FallbackController

  @max_limit 50

  def create(conn, %{"query" => query} = params) when is_binary(query) do
    with {:ok, query} <- parse_query(query),
         {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, result} <- Lookup.run(query, limit: limit) do
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
end
