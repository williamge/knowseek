defmodule Knowseek.Cards.OpenMeteo do
  @moduledoc """
  A small client for Open-Meteo's forecast API (`https://api.open-meteo.com/v1/forecast`),
  for `Knowseek.Cards.Providers.OpenMeteo` (task 033, ADR 0022).

  The free API needs no key. It is for non-commercial use and its data is CC BY 4.0, so
  the card shows the credit (ADR 0022).

  Requests send a descriptive User-Agent, have a short timeout, and never retry (the
  retry is the next refresh, after the backoff of `Knowseek.Cache`). A non-200 answer is
  `{:error, {:http_status, status}}`. HTTP 429 is `{:error, {:rate_limited, retry_after_ms}}`,
  which stops every fetch of the cards cache for that long.

  Configuration:

      config :knowseek, Knowseek.Cards.OpenMeteo,
        base_url: "https://api.open-meteo.com/v1/forecast",
        user_agent: "...",
        receive_timeout: 4_000,
        req_options: []     # merged into every request (tests stub here)
  """

  require Logger

  @defaults [
    base_url: "https://api.open-meteo.com/v1/forecast",
    user_agent: "Knowseek/0.1.0 (https://github.com/williamge/knowseek)",
    receive_timeout: 4_000,
    req_options: []
  ]

  @doc """
  GETs the forecast with the query `params` and returns the decoded JSON object.
  """
  @spec get(keyword()) :: {:ok, map()} | {:error, term()}
  def get(params) when is_list(params) do
    config = config()
    Logger.debug("Open-Meteo GET forecast")

    request =
      Req.new(
        url: config[:base_url],
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
