defmodule Knowseek.Discovery.Sources.Wikipedia do
  @moduledoc """
  Discovery source for Wikipedia, through the MediaWiki Action API.

  Searches article titles and text (`list=search`), then fetches the plain
  text extract of each of the top results (`prop=extracts`). MediaWiki
  returns only one whole-article extract per request, so pages are fetched
  one at a time. Serial requests also follow the Wikimedia API etiquette.

  Configuration (all optional):

      config :knowseek, Knowseek.Discovery.Sources.Wikipedia,
        base_url: "https://en.wikipedia.org/w/api.php",
        limit: 3,              # pages per query
        max_chars: 40_000,     # longer extracts are cut at a paragraph break
        user_agent: "...",     # Wikimedia policy: identify the client
        req_options: []        # merged into every Req request (tests stub here)
  """
  @behaviour Knowseek.Discovery.Source

  @defaults [
    base_url: "https://en.wikipedia.org/w/api.php",
    limit: 3,
    max_chars: 40_000,
    user_agent: "Knowseek/0.1.0 (https://github.com/williamge/knowseek)",
    req_options: []
  ]

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
      srsearch: query,
      srlimit: config[:limit],
      srnamespace: 0,
      srprop: ""
    ]

    with {:ok, %{"query" => %{"search" => results}}} <- api_get(params, config) do
      {:ok, Enum.map(results, & &1["pageid"])}
    end
  end

  defp collect_pages(pageids, config) do
    Enum.reduce_while(pageids, {:ok, []}, fn pageid, {:ok, acc} ->
      case fetch_page(pageid, config) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, candidate} -> {:cont, {:ok, [candidate | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, candidates} -> {:ok, Enum.reverse(candidates)}
      error -> error
    end
  end

  defp fetch_page(pageid, config) do
    params = [
      prop: "extracts|info",
      explaintext: 1,
      exsectionformat: "plain",
      inprop: "url",
      pageids: pageid
    ]

    with {:ok, %{"query" => %{"pages" => pages}}} <- api_get(params, config) do
      {:ok, pages |> List.first() |> to_candidate(config[:max_chars])}
    end
  end

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
    end
  end

  defp to_candidate(_page, _max_chars), do: nil

  @doc false
  # Cuts `body` to at most `max_chars`, at the last paragraph break if there is one.
  def truncate(body, max_chars) do
    if String.length(body) <= max_chars do
      body
    else
      head = String.slice(body, 0, max_chars)

      case :binary.matches(head, "\n\n") do
        [] -> head
        matches -> binary_part(head, 0, matches |> List.last() |> elem(0))
      end
    end
  end

  defp api_get(params, config) do
    request =
      Req.new(
        url: config[:base_url],
        params: [action: "query", format: "json", formatversion: 2] ++ params,
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
