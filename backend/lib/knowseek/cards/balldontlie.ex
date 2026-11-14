defmodule Knowseek.Cards.Balldontlie do
  @moduledoc """
  A small client for the balldontlie NBA API (`https://api.balldontlie.io/v1`),
  for `Knowseek.Cards.Providers.Nba` (ADR 0028).

  The API needs a key: a free account gives one (5 requests a minute; teams
  and games, but no injuries or standings). Each operator uses their own key
  (`BALLDONTLIE_API_KEY`, `config/runtime.exs`); the terms forbid sharing it.
  Without a key there is no NBA card (`configured?/0`). The terms allow
  caching and displaying the data, with no credit required.

  Requests send the key in the `Authorization` header and a descriptive
  User-Agent, have a short timeout, and never retry (the retry is the next
  refresh, after the backoff of `Knowseek.Cache`). HTTP 401 is
  `{:error, :unauthorized}` (no key, a wrong key, or a tier without the
  endpoint), HTTP 429 is `{:error, {:rate_limited, retry_after_ms}}`, which
  stops every fetch of the NBA cards cache for that long, and every other
  status is `{:error, {:http_status, status}}`.

  Configuration:

      config :knowseek, Knowseek.Cards.Balldontlie,
        base_url: "https://api.balldontlie.io/v1",
        api_key: nil,       # BALLDONTLIE_API_KEY
        user_agent: "...",
        receive_timeout: 4_000,
        req_options: []     # merged into every request (tests stub here)

  Downloads are counted for the network budget, source `balldontlie` (ADR 0034).
  """

  require Logger

  @defaults [
    base_url: "https://api.balldontlie.io/v1",
    api_key: nil,
    user_agent: "Knowseek/0.1.0 (https://github.com/williamge/knowseek)",
    receive_timeout: 4_000,
    req_options: []
  ]

  @doc "Whether an API key is configured. Without one the NBA card is off."
  @spec configured?() :: boolean()
  def configured? do
    case config()[:api_key] do
      key when is_binary(key) -> String.trim(key) != ""
      _none -> false
    end
  end

  @doc """
  GETs `path` (for example `"teams"`) below the base URL and returns the
  decoded JSON object. `params` is a list of `{name, value}` pairs, so that a
  name can repeat (`{"team_ids[]", 18}`).
  """
  @spec get(String.t(), [{String.t(), term()}]) :: {:ok, map()} | {:error, term()}
  def get(path, params \\ []) when is_binary(path) and is_list(params) do
    config = config()
    Logger.debug("balldontlie GET #{path}")

    request =
      Req.new(
        url: config[:base_url] <> "/" <> path,
        params: params,
        headers: [user_agent: config[:user_agent], authorization: config[:api_key] || ""],
        receive_timeout: config[:receive_timeout],
        retry: false
      )
      |> Req.merge(config[:req_options])
      |> Knowseek.Download.count("balldontlie")

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 200}} ->
        {:error, :unexpected_body}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: 429} = response} ->
        {:error, Knowseek.Cache.rate_limited(response)}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp config do
    Keyword.merge(@defaults, Application.get_env(:knowseek, __MODULE__, []))
  end
end
