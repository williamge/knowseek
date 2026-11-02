defmodule Knowseek.Entities.Wikidata do
  @moduledoc """
  `Knowseek.Entities.Resolver` for Wikidata.

  Two requests per resolution, however many candidates there are:

    1. `wbsearchentities` for the candidates (id, label, description), best
       match first.
    2. One `wbgetentities` call for the claims and sitelinks of all of them
       (ids joined with `|`).

  What is read from an item:

    * `P31` (instance of) into `types`.
    * `P625` (coordinate location) into `coordinates`: the preferred claim,
      else the first one that is not deprecated, on Earth only.
    * `P414` (stock exchange) with its `P249` (ticker symbol) qualifier into
      `exchange_tickers`. The ticker is a qualifier on the exchange claim,
      not a claim of its own. An item can list several exchanges (Sony:
      Tokyo and New York); all of them are kept. Deprecated claims, claims
      with an end time (`P582`), and claims without a ticker are skipped.
    * `P118` (league) into `leagues`: the leagues a team plays in now.
      Deprecated claims and claims with an end time (`P582`) are skipped,
      so a defunct team that once played in the NBA has none.
    * `sitelinks` into the sitelink count and the English Wikipedia title.

  Requests send a descriptive User-Agent (Wikimedia policy) and no `maxlag`,
  and never retry: Wikidata rate limits, and the retry is the next refresh
  after the backoff of `Knowseek.Cache`. A non-200 answer is
  `{:error, {:http_status, status}}`, an API error body is
  `{:error, {:api_error, code}}`, and a timeout is the transport exception.
  HTTP 429 and a `maxlag` API error (both come with `Retry-After`) are
  `{:error, {:rate_limited, retry_after_ms}}`, which makes `Knowseek.Cache`
  stop all Wikidata fetches for that long; for `maxlag` the time is clamped
  to 1 to 300 seconds.

  Why no `maxlag`: MediaWiki says "Interactive tasks (where a user is waiting
  for the result) may omit the maxlag parameter. Noninteractive tasks should
  always use it" (Manual:Maxlag_parameter). A card lookup is interactive, and
  it is cached. Wikidata's `maxlag` also counts the lag of the Query Service
  (wdqs, the SPARQL backend), which `wbsearchentities` and `wbgetentities`
  do not use: on 2026-11-02 wdqs lag (7 to 8 s) made every request with
  `maxlag=5` fail with HTTP 200 and `error.code: "maxlag"` while the same
  requests without it worked. Our own cache, single flight, concurrency cap
  and rate-limit backoff are the courtesy instead.

  Configuration (all optional):

      config :knowseek, Knowseek.Entities.Wikidata,
        base_url: "https://www.wikidata.org/w/api.php",
        search_limit: 20,      # candidates per query; the API allows 50
        user_agent: "...",
        req_options: []        # merged into every Req request (tests stub here)
  """
  @behaviour Knowseek.Entities.Resolver

  alias Knowseek.Entities.Entity

  require Logger

  @min_maxlag_backoff 1_000
  @max_maxlag_backoff 300_000

  @defaults [
    base_url: "https://www.wikidata.org/w/api.php",
    search_limit: 20,
    user_agent: "Knowseek/0.1.0 (https://github.com/williamge/knowseek)",
    req_options: []
  ]

  # Wikidata items live on Earth; other globes are craters and the like.
  @earth "http://www.wikidata.org/entity/Q2"

  @impl true
  def search(text, _opts) do
    config = config()

    with {:ok, hits} <- search_hits(text, config),
         {:ok, details} <- entity_details(hits, config) do
      {:ok, build_entities(hits, details)}
    end
  end

  defp search_hits(text, config) do
    params = [
      action: "wbsearchentities",
      search: text,
      language: "en",
      uselang: "en",
      type: "item",
      limit: config[:search_limit]
    ]

    case api_get(params, config) do
      {:ok, %{"search" => hits}} when is_list(hits) -> {:ok, hits}
      {:ok, _body} -> {:error, :unexpected_body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp entity_details([], _config), do: {:ok, %{}}

  defp entity_details(hits, config) do
    params = [
      action: "wbgetentities",
      ids: Enum.map_join(hits, "|", & &1["id"]),
      props: "claims|sitelinks"
    ]

    case api_get(params, config) do
      {:ok, %{"entities" => entities}} when is_map(entities) -> {:ok, entities}
      {:ok, _body} -> {:error, :unexpected_body}
      {:error, reason} -> {:error, reason}
    end
  end

  # A hit whose item has no details (deleted since the search) is dropped.
  defp build_entities(hits, details) do
    for hit <- hits,
        item = details[hit["id"]],
        is_map(item) and not is_map_key(item, "missing") do
      build_entity(hit, item)
    end
  end

  defp build_entity(hit, item) do
    claims = item["claims"] || %{}
    sitelinks = item["sitelinks"] || %{}

    %Entity{
      id: hit["id"],
      label: hit["label"],
      description: hit["description"],
      types: claims |> Map.get("P31", []) |> Enum.flat_map(&item_ids/1),
      sitelinks: map_size(sitelinks),
      wikipedia_title: get_in(sitelinks, ["enwiki", "title"]),
      coordinates: coordinates(Map.get(claims, "P625", [])),
      exchange_tickers: exchange_tickers(Map.get(claims, "P414", [])),
      cik: cik(Map.get(claims, "P5531", [])),
      leagues: leagues(Map.get(claims, "P118", []))
    }
  end

  defp item_ids(%{
         "mainsnak" => %{"snaktype" => "value", "datavalue" => %{"value" => %{"id" => id}}}
       }),
       do: [id]

  defp item_ids(_claim), do: []

  defp coordinates(claims) do
    usable = Enum.reject(claims, &(&1["rank"] == "deprecated"))
    claim = Enum.find(usable, &(&1["rank"] == "preferred")) || List.first(usable)

    case claim do
      %{
        "mainsnak" => %{
          "snaktype" => "value",
          "datavalue" => %{
            "value" => %{"latitude" => lat, "longitude" => lon, "globe" => @earth}
          }
        }
      }
      when is_number(lat) and is_number(lon) ->
        %{latitude: lat, longitude: lon}

      _no_coordinates ->
        nil
    end
  end

  defp exchange_tickers(claims) do
    for claim <- claims,
        claim["rank"] != "deprecated",
        not Map.has_key?(claim["qualifiers"] || %{}, "P582"),
        [exchange] <- [item_ids(claim)],
        ticker <- tickers(claim["qualifiers"] || %{}) do
      %{exchange: exchange, ticker: ticker}
    end
  end

  # The SEC Central Index Key: ten digits, with leading zeros. A deprecated
  # claim and a value of another shape are not a key; a preferred claim wins
  # over a normal one, then the first.
  defp cik(claims) do
    keys =
      for %{
            "rank" => rank,
            "mainsnak" => %{"snaktype" => "value", "datavalue" => %{"value" => v}}
          } <-
            claims,
          rank != "deprecated",
          is_binary(v) and v =~ ~r/\A\d{10}\z/ do
        {rank, v}
      end

    case Enum.find(keys, &match?({"preferred", _}, &1)) || List.first(keys) do
      {_rank, key} -> key
      nil -> nil
    end
  end

  defp leagues(claims) do
    for claim <- claims,
        claim["rank"] != "deprecated",
        not Map.has_key?(claim["qualifiers"] || %{}, "P582"),
        league <- item_ids(claim) do
      league
    end
  end

  defp tickers(qualifiers) do
    for %{"snaktype" => "value", "datavalue" => %{"value" => ticker}} <-
          Map.get(qualifiers, "P249", []),
        is_binary(ticker) and ticker != "" do
      ticker
    end
  end

  defp api_get(params, config) do
    Logger.debug("Wikidata #{params[:action]}")

    request =
      Req.new(
        url: config[:base_url],
        params: [format: "json"] ++ params,
        headers: [user_agent: config[:user_agent]],
        receive_timeout: 10_000,
        retry: false
      )
      |> Req.merge(config[:req_options])

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: %{"error" => %{"code" => "maxlag"}}} = response} ->
        {:rate_limited, ms} = Knowseek.Cache.rate_limited(response)
        {:error, {:rate_limited, ms |> max(@min_maxlag_backoff) |> min(@max_maxlag_backoff)}}

      {:ok, %Req.Response{status: 200, body: %{"error" => %{"code" => code}}}} ->
        {:error, {:api_error, code}}

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
