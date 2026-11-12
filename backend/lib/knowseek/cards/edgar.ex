defmodule Knowseek.Cards.Edgar do
  @moduledoc """
  A small client for the SEC's EDGAR data API (`https://data.sec.gov`), for
  `Knowseek.Cards.Providers.Company` (ADR 0021).

  The data is public and the SEC allows reuse ("Information presented on
  sec.gov is considered public information and may be copied or further
  distributed"). Its fair-access rules ask for a declared User-Agent and at most
  10 requests per second. A card costs two requests an hour.

  ## User-Agent

  The default is `Knowseek/0.1 (self-hosted instance)`, which `data.sec.gov`
  accepted on 2026-11-02. The SEC asks every automated user for a name and a
  contact address and can block an undeclared tool (the answer is HTTP 403,
  "Undeclared Automated Tool"; it blocked, for example, a User-Agent that
  contains `github`). Operators should set `SEC_USER_AGENT` (`config/runtime.exs`),
  for example `"My Company admin@example.com"`.

  ## Errors

  Requests have a short timeout and never retry (the retry is the next
  refresh, after the backoff of `Knowseek.Cache`). HTTP 404 is
  `{:error, :not_found}`, HTTP 403 is `{:error, :forbidden}` (the caller logs
  the advice above and stops fetching), HTTP 429 is
  `{:error, {:rate_limited, retry_after_ms}}`, every other status is
  `{:error, {:http_status, status}}`.

  Configuration:

      config :knowseek, Knowseek.Cards.Edgar,
        base_url: "https://data.sec.gov",
        user_agent: "Knowseek/0.1 (self-hosted instance)",
        receive_timeout: 5_000,
        req_options: []     # merged into every request (tests stub here)
  """

  require Logger

  @defaults [
    base_url: "https://data.sec.gov",
    user_agent: "Knowseek/0.1 (self-hosted instance)",
    receive_timeout: 5_000,
    req_options: []
  ]

  @doc "The decoded `submissions/CIK<cik>.json` of a company (`cik` has ten digits)."
  @spec submissions(String.t()) :: {:ok, map()} | {:error, term()}
  def submissions(cik), do: get("submissions/CIK#{cik}.json")

  @doc "The reported values of the `dei` concept `concept` of a company (XBRL company concept)."
  @spec dei_concept(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def dei_concept(cik, concept), do: get("api/xbrl/companyconcept/CIK#{cik}/dei/#{concept}.json")

  defp get(path) do
    config = config()
    Logger.debug("EDGAR GET #{path}")

    request =
      Req.new(
        url: config[:base_url] <> "/" <> path,
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

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: 403}} ->
        {:error, :forbidden}

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
