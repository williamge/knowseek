defmodule Knowseek.Discovery.Sources.Wikipedia do
  @moduledoc """
  Discovery source for Wikipedia, through the MediaWiki Action API.

  Searches article titles and text (`list=search`), then fetches the plain
  text extract of each of the top results (`prop=extracts`). MediaWiki
  returns only one whole-article extract per request, so one discovery run
  fetches its pages one at a time. Every request sends `maxlag`, so the API
  refuses work when its database replicas lag. Several discovery jobs can
  still run at the same time (see the `discovery` Oban queue).

  Each candidate also carries `:source_updated_at`, the timestamp of the
  page's latest revision (`prop=revisions`, same request). It is the revision
  timestamp, not `touched`: `touched` also moves when a template changes.

  Disambiguation pages and pages without text are skipped. If one page fetch
  fails, the other pages are still returned. The source returns an error
  only when the search fails or every page fetch fails.

  Each candidate carries `:monthly_views`, the page's views per 30 days, from
  the same request as the text (`prop=pageviews`, the average of the last 60
  days that have data). It is left out when the API has no figure. See ADR
  0018.

  Configuration (all optional):

      config :knowseek, Knowseek.Discovery.Sources.Wikipedia,
        base_url: "https://en.wikipedia.org/w/api.php",
        limit: 3,              # pages per query
        max_chars: 40_000,     # longer extracts are cut, at a paragraph break if possible
        user_agent: "...",     # Wikimedia policy: identify the client
        req_options: []        # merged into every Req request (tests stub here)
  """
  @behaviour Knowseek.Discovery.Source

  require Logger

  @defaults [
    base_url: "https://en.wikipedia.org/w/api.php",
    limit: 3,
    max_chars: 40_000,
    user_agent: "Knowseek/0.1.0 (https://github.com/williamge/knowseek)",
    req_options: []
  ]

  # CirrusSearch rejects longer queries with `cirrussearch-query-too-long`.
  @max_query_length 300

  # The PageViewInfo extension returns at most 60 daily figures per page.
  @pageview_days 60

  @impl true
  def name, do: "wikipedia"

  @impl true
  def discover(query, _opts) do
    config = config()

    with {:ok, pageids} <- search(query, config) do
      collect_pages(pageids, config)
    end
  end

  defp search(query, config) do
    params = [
      list: "search",
      srsearch: search_text(query),
      srlimit: config[:limit],
      srnamespace: 0,
      srprop: ""
    ]

    case api_get(params, config) do
      {:ok, %{"query" => %{"search" => results}}} -> {:ok, Enum.map(results, & &1["pageid"])}
      {:ok, _body} -> {:error, :unexpected_body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # Cuts `query` to the CirrusSearch limit, at a word boundary if possible.
  # The limit counts code points, not graphemes.
  def search_text(query) do
    codepoints = String.codepoints(query)

    if length(codepoints) <= @max_query_length do
      query
    else
      head = codepoints |> Enum.take(@max_query_length) |> Enum.join()

      case String.split(head, ~r/\s+(?=\S*$)/u, parts: 2) do
        [words, _partial_word] when words != "" -> words
        _no_space -> head
      end
    end
  end

  defp collect_pages(pageids, config) do
    results = Enum.map(pageids, &fetch_page(&1, config))
    candidates = for {:ok, candidate} <- results, candidate != nil, do: candidate
    errors = for {:error, reason} <- results, do: reason

    Enum.each(errors, &Logger.warning("wikipedia page fetch failed: #{inspect(&1)}"))

    case {candidates, errors} do
      {[], [reason | _rest]} -> {:error, reason}
      _some_pages -> {:ok, candidates}
    end
  end

  defp fetch_page(pageid, config) do
    params = [
      prop: "extracts|info|pageprops|pageviews|revisions",
      rvprop: "timestamp",
      explaintext: 1,
      exsectionformat: "plain",
      inprop: "url",
      ppprop: "disambiguation",
      pvipdays: @pageview_days,
      pageids: pageid
    ]

    case api_get(params, config) do
      {:ok, %{"query" => %{"pages" => [page | _rest]}}} ->
        {:ok, to_candidate(page, config[:max_chars])}

      {:ok, _body} ->
        {:error, :unexpected_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Disambiguation pages only list links to other pages.
  defp to_candidate(%{"pageprops" => %{"disambiguation" => _}}, _max_chars), do: nil

  # Missing pages and pages without text (for example a page deleted between
  # the search and the fetch) yield no candidate.
  defp to_candidate(%{"pageid" => pageid, "extract" => extract} = page, max_chars)
       when is_binary(extract) do
    case String.trim(extract) do
      "" ->
        nil

      body ->
        %{
          url: page["canonicalurl"] || page["fullurl"],
          title: page["title"],
          body: truncate(body, max_chars),
          metadata: %{"pageid" => pageid}
        }
        |> put_monthly_views(page["pageviews"])
        |> put_source_updated_at(page["revisions"])
    end
  end

  defp to_candidate(_page, _max_chars), do: nil

  # The candidate carries no `:monthly_views` when the API has no figure, so
  # that re-ingesting it keeps an earlier one.
  defp put_monthly_views(candidate, pageviews) do
    case monthly_views(pageviews) do
      nil -> candidate
      views -> Map.put(candidate, :monthly_views, views)
    end
  end

  # The candidate carries no `:source_updated_at` when the API has no revision,
  # so that re-ingesting it keeps an earlier one.
  defp put_source_updated_at(candidate, revisions) do
    case revision_time(revisions) do
      nil -> candidate
      time -> Map.put(candidate, :source_updated_at, time)
    end
  end

  @doc false
  # `revisions` is the `prop=revisions` value: a list with the latest
  # revision, `[%{"timestamp" => "2026-10-29T03:01:48Z"}]`. Returns its time,
  # or `nil` when there is none or it does not parse.
  @spec revision_time(term()) :: DateTime.t() | nil
  def revision_time([%{"timestamp" => timestamp} | _rest]) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, time, _offset} -> time
      {:error, _reason} -> nil
    end
  end

  def revision_time(_revisions), do: nil

  @doc false
  # `pageviews` is the `prop=pageviews` value: a map of date to the views of
  # that day, for the last `@pageview_days` days. A day without data (today,
  # or a page that did not exist yet) is `nil`. Returns the average over the
  # days with data, scaled to 30 days, or `nil` when no day has data.
  @spec monthly_views(map() | nil) :: non_neg_integer() | nil
  def monthly_views(%{} = pageviews) do
    case Enum.filter(Map.values(pageviews), &is_integer/1) do
      [] -> nil
      days -> round(Enum.sum(days) / length(days) * 30)
    end
  end

  def monthly_views(_pageviews), do: nil

  @doc false
  # Cuts `body` to at most `max_chars`. Cuts at the last paragraph break if
  # that break is in the second half of the allowed text, so that a break
  # near the start does not discard most of the text.
  def truncate(body, max_chars) do
    if String.length(body) <= max_chars do
      body
    else
      head = String.slice(body, 0, max_chars)

      case :binary.matches(head, "\n\n") |> List.last() do
        {offset, _length} when offset >= div(byte_size(head), 2) -> binary_part(head, 0, offset)
        _no_late_break -> head
      end
    end
  end

  defp api_get(params, config) do
    request =
      Req.new(
        url: config[:base_url],
        params: [action: "query", format: "json", formatversion: 2, maxlag: 5] ++ params,
        headers: [user_agent: config[:user_agent]],
        receive_timeout: 15_000
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
