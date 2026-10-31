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
    * `sitelinks` into the sitelink count and the English Wikipedia title.

  Requests send `maxlag` and a descriptive User-Agent (Wikimedia policy), and
  never retry: Wikidata rate limits, and the retry is the next refresh after
  the backoff of `Knowseek.Cache`. A non-200 answer is
  `{:error, {:http_status, status}}`, an API error body is
  `{:error, {:api_error, code}}`, and a timeout is the transport exception.

  Configuration (all optional):

      config :knowseek, Knowseek.Entities.Wikidata,
        base_url: "https://www.wikidata.org/w/api.php",
        search_limit: 20,      # candidates per query; the API allows 50
        user_agent: "...",
        req_options: []        # merged into every Req request (tests stub here)
  """
  @behaviour Knowseek.Entities.Resolver

  alias Knowseek.Entities.Entity

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
      exchange_tickers: exchange_tickers(Map.get(claims, "P414", []))
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

  defp tickers(qualifiers) do
    for %{"snaktype" => "value", "datavalue" => %{"value" => ticker}} <-
          Map.get(qualifiers, "P249", []),
        is_binary(ticker) and ticker != "" do
      ticker
    end
  end

  defp api_get(params, config) do
    request =
      Req.new(
        url: config[:base_url],
        params: [format: "json", maxlag: 5] ++ params,
        headers: [user_agent: config[:user_agent]],
        receive_timeout: 10_000,
        retry: false
      )
      |> Req.merge(config[:req_options])

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: %{"error" => %{"code" => code}}}} ->
        {:error, {:api_error, code}}

      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 200}} ->
        {:error, :unexpected_body}

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
