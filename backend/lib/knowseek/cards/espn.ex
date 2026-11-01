defmodule Knowseek.Cards.Espn do
  @moduledoc """
  A small client for ESPN's public site API
  (`https://site.api.espn.com/apis/site/v2/sports/<sport>/<league>/...`), for
  the providers under `Knowseek.Cards.Providers`.

  The API is unofficial and undocumented, so every caller reads only the
  fields it needs and treats a missing one as "unknown". Its endpoints send
  `cache-control: max-age=1..3`, so callers must not poll faster than a few
  seconds; the card TTLs and backoffs make sure of that.

  Requests send a descriptive User-Agent, have a short timeout, and never
  retry (the retry is the next refresh, after the backoff of
  `Knowseek.Cache`). A non-200 answer is `{:error, {:http_status, status}}`.
  HTTP 429 is `{:error, {:rate_limited, retry_after_ms}}`, which stops every
  fetch of the cards cache for that long.

  Configuration:

      config :knowseek, Knowseek.Cards.Espn,
        base_url: "https://site.api.espn.com/apis/site/v2/sports",
        user_agent: "...",
        receive_timeout: 4_000,
        req_options: []     # merged into every request (tests stub here)
  """

  require Logger

  @defaults [
    base_url: "https://site.api.espn.com/apis/site/v2/sports",
    user_agent: "Knowseek/0.1.0 (https://github.com/williamge/knowseek)",
    receive_timeout: 4_000,
    req_options: []
  ]

  @doc """
  GETs `path` (for example `"basketball/nba/teams"`) below the base URL and
  returns the decoded JSON object.
  """
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(path, params \\ []) when is_binary(path) do
    config = config()
    Logger.debug("ESPN GET #{path}")

    request =
      Req.new(
        url: config[:base_url] <> "/" <> path,
        params: params,
        headers: [user_agent: config[:user_agent]],
        receive_timeout: config[:receive_timeout],
        retry: false
      )
      |> Req.merge(config[:req_options])

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 200}} ->
        {:error, :unexpected_body}

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
