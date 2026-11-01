defmodule Knowseek.Cards.TwelveData do
  @moduledoc """
  A small client for the Twelve Data REST API (`https://api.twelvedata.com`),
  for `Knowseek.Cards.Providers.TwelveDataCompany` (ADR 0021).

  The API needs a key (`TWELVEDATA_API_KEY`, see `config/runtime.exs`). It
  goes in the `Authorization: apikey <key>` header, the documented
  alternative to the `apikey` query parameter, so that it never appears in a
  URL, a log line or an exception message. Without a key `api_key/0` is `nil`
  and the provider handles no entity.

  Requests send a short timeout and never retry (the retry is the next
  refresh, after the backoff of `Knowseek.Cache`). Twelve Data reports an
  error as a JSON body `{"code": 4xx, "status": "error", "message": ...}`,
  usually with the same HTTP status. HTTP 429 and a body with `code` 429 (the
  per-minute credit limit) are both `{:error, {:rate_limited, retry_after_ms}}`,
  which stops every fetch of the cards cache for that long; every other error
  is `{:error, {:http_status, status}}` or `{:error, {:twelve_data, code}}`.
  The error message is not kept: it can echo request details.

  Configuration:

      config :knowseek, Knowseek.Cards.TwelveData,
        base_url: "https://api.twelvedata.com",
        api_key: nil,            # set from TWELVEDATA_API_KEY in runtime.exs
        user_agent: "...",
        receive_timeout: 4_000,
        req_options: []          # merged into every request (tests stub here)
  """

  require Logger

  @defaults [
    base_url: "https://api.twelvedata.com",
    api_key: nil,
    user_agent: "Knowseek/0.1.0 (https://github.com/williamge/knowseek)",
    receive_timeout: 4_000,
    req_options: []
  ]

  # Twelve Data's credits reset every minute.
  @rate_limit_ms :timer.seconds(60)

  @doc "The configured API key, or `nil` when none is set (or it is blank)."
  @spec api_key() :: String.t() | nil
  def api_key do
    case config()[:api_key] do
      key when is_binary(key) -> if String.trim(key) == "", do: nil, else: key
      _no_key -> nil
    end
  end

  @doc """
  GETs `path` (for example `"quote"`) below the base URL and returns the
  decoded JSON object.
  """
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(path, params \\ []) when is_binary(path) do
    config = config()

    case api_key() do
      nil -> {:error, :no_api_key}
      key -> request(config, key, path, params)
    end
  end

  defp request(config, key, path, params) do
    Logger.debug("Twelve Data GET #{path}")

    request =
      Req.new(
        url: config[:base_url] <> "/" <> path,
        params: params,
        headers: [user_agent: config[:user_agent], authorization: "apikey " <> key],
        receive_timeout: config[:receive_timeout],
        retry: false
      )
      |> Req.merge(config[:req_options])

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: %{"status" => "error", "code" => code}}} ->
        {:error, error(code)}

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

  defp error(429), do: {:rate_limited, @rate_limit_ms}
  defp error(code), do: {:twelve_data, code}

  defp config do
    Keyword.merge(@defaults, Application.get_env(:knowseek, __MODULE__, []))
  end
end
