defmodule Knowseek.Discovery.Sources.MediaWiki do
  @moduledoc """
  Discovery through the MediaWiki Action API of one Wikimedia site. The
  sources `Knowseek.Discovery.Sources.Wikipedia` and
  `Knowseek.Discovery.Sources.Wikibooks` are thin modules over it: each
  passes its `t:site/0`.

  Searches page titles and text (`list=search`) in the main namespace, or in
  the site's `search_namespaces`, then fetches the plain text extract of each
  of the top results (`prop=extracts`). A site with `search_namespaces`
  sends one search per namespace, in that order, and keeps the top results
  of the first, then of the next, without duplicates, cut to `limit`: one
  search over several namespaces ranks main-namespace pages first (ADR
  0029). The source returns an error when any of its searches fails.

  MediaWiki returns only one whole-page extract per request, so one
  discovery run fetches its pages one at a time. Every request sends
  `maxlag`, so the API refuses work when its database replicas
  lag, and runs as a `:background` caller of the shared Wikimedia slots
  (`Knowseek.Wikimedia`, ADR 0027). Req's retries, and their waits, keep the
  slot.

  Each candidate also carries `:source_updated_at`, the timestamp of the
  page's latest revision (`prop=revisions`, same request). It is the revision
  timestamp, not `touched`: `touched` also moves when a template changes.

  Disambiguation pages and pages without text are skipped. If one page fetch
  fails, the other pages are still returned. The source returns an error
  only when the search fails or every page fetch fails.

  A site with `skip_compilations: true` also skips compilations: pages that
  transclude 2 or more main-namespace pages (`prop=templates` with
  `tlnamespace=0`, same request), such as a Wikibooks print version built
  from its chapters. Their text is other pages' text, which is fetched on its
  own, and as one long document it outranks the chapter that answers the
  query (ADR 0029). Other sites send the same request as before.

  Each candidate carries `:monthly_views`, the page's views per 30 days, from
  the same request as the text (`prop=pageviews`, the average of the last 60
  days that have data). It is left out when the API has no figure. See ADR
  0018.

  Each candidate carries the license fields (ADR 0026): the site's
  `:license`, credit `:credit` with a link to the page, `modified: true` (a
  plain-text extract, maybe cut) and `share: "full"`.

  `discover/3` takes the `:on_bytes` option of `Knowseek.Discovery.Source`:
  a response step (`Knowseek.Download.measure/2`) reports the size of each
  response, headers and body as received (still compressed, once per
  attempt). The source only calls the function; `Knowseek.Discovery` owns it
  (rule 3, ADR 0031, ADR 0034).

  Each candidate carries `:links`, the page's external links (`prop=extlinks`
  with `ellimit=max`, same request), in page order; `[]` when there are none.
  One response holds at most 500. A page with more answers with `elcontinue`,
  and the source sends up to 10 more requests (`prop=extlinks` only), so at
  most 5,500 links in all. Only `elcontinue` is followed: other modules
  (`templates` on Wikibooks) also report a `continue`. A failed continuation
  keeps the page and the links read so far. A page that yields no candidate
  sends no continuation request. `links/3` reads the links of a page fetched
  earlier, for the link backfill (#88, ADR 0032).

  `link_candidates/3` reads the pages a stored page links to on the same
  site, with their short descriptions (`generator=links` with
  `prop=description`, one request, two for a page with more than 500 links),
  for the background crawl (#89, ADR 0033). It keeps real pages of the
  site's `link_namespaces` and leaves out red links, disambiguation pages and
  the page itself. `page/3` fetches one such page by its id, as `discover/3`
  would return it (same request, same fields, same `:links`), for the same
  crawl.

  Configuration, under the source module's key (all optional):

      config :knowseek, Knowseek.Discovery.Sources.Wikipedia,
        base_url: "https://en.wikipedia.org/w/api.php", # default: the site's
        limit: 3,              # pages per query
        max_chars: 40_000,     # longer extracts are cut, at a paragraph break if possible
        user_agent: "...",     # Wikimedia policy: identify the client
        req_options: []        # merged into every Req request (tests stub here)
  """

  require Logger

  @typedoc """
  One MediaWiki site: `name` (the source name, stored in `documents.source`),
  `base_url` (its `api.php`), `license` (SPDX id of its text), `credit` (the
  name in the attribution), `config` (the application env key of its
  options, the source module) and, optionally, `skip_compilations` (default
  `false`), `search_namespaces` (default `[0]`, the main namespace; see
  the module doc) and `link_namespaces` (default `[0]`: the namespaces whose
  pages `link_candidates/3` keeps).
  """
  @type site :: %{
          required(:name) => String.t(),
          required(:base_url) => String.t(),
          required(:license) => String.t(),
          required(:credit) => String.t(),
          required(:config) => module(),
          optional(:skip_compilations) => boolean(),
          optional(:search_namespaces) => [non_neg_integer()],
          optional(:link_namespaces) => [non_neg_integer()]
        }

  @defaults [
    limit: 3,
    max_chars: 40_000,
    user_agent: "Knowseek/0.1.0 (https://github.com/williamge/knowseek)",
    req_options: []
  ]

  # CirrusSearch rejects longer queries with `cirrussearch-query-too-long`.
  @max_query_length 300

  # The PageViewInfo extension returns at most 60 daily figures per page.
  @pageview_days 60

  # A page that transcludes this many main-namespace pages is a compilation.
  @compilation_min_pages 2

  # One response holds at most 500 external links (`ellimit=max`). A page with
  # more gets at most this many continuation requests (5,500 links in all).
  @max_link_requests 10

  # One response holds at most 500 linked pages. A page with more links gets
  # this many requests in all (1,000 links).
  @max_candidate_requests 2

  @doc """
  Finds the top pages of `site` for `query`. See the module doc. `opts` may
  hold `:on_bytes`, called with the size of every response (see
  `Knowseek.Discovery.Source`).
  """
  @spec discover(String.t(), site(), keyword()) ::
          {:ok, [Knowseek.Discovery.Source.candidate()]} | {:error, term()}
  def discover(query, site, opts \\ []) do
    config = config(site, opts)

    with {:ok, pageids} <- search_all(query, site, config) do
      collect_pages(pageids, site, config)
    end
  end

  # One search per namespace; the earlier namespace's results come first.
  defp search_all(query, site, config) do
    site
    |> Map.get(:search_namespaces, [0])
    |> Enum.reduce_while({:ok, []}, fn namespace, {:ok, pageids} ->
      case search(query, namespace, config) do
        {:ok, found} -> {:cont, {:ok, pageids ++ found}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pageids} -> {:ok, pageids |> Enum.uniq() |> Enum.take(config[:limit])}
      {:error, reason} -> {:error, reason}
    end
  end

  defp search(query, namespace, config) do
    params = [
      list: "search",
      srsearch: search_text(query),
      srlimit: config[:limit],
      srnamespace: namespace,
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

  defp collect_pages(pageids, site, config) do
    results = Enum.map(pageids, &fetch_page(&1, site, config))
    candidates = for {:ok, candidate} <- results, candidate != nil, do: candidate
    errors = for {:error, reason} <- results, do: reason

    Enum.each(errors, &Logger.warning("#{site.name} page fetch failed: #{inspect(&1)}"))

    case {candidates, errors} do
      {[], [reason | _rest]} -> {:error, reason}
      _some_pages -> {:ok, candidates}
    end
  end

  defp fetch_page(pageid, site, config) do
    params =
      [
        prop: "extracts|info|pageprops|pageviews|revisions|extlinks",
        rvprop: "timestamp",
        explaintext: 1,
        exsectionformat: "plain",
        inprop: "url",
        ppprop: "disambiguation",
        pvipdays: @pageview_days,
        pageids: pageid,
        ellimit: "max"
      ]
      |> put_compilation_params(site)

    case api_get(params, config) do
      {:ok, %{"query" => %{"pages" => [page | _rest]}} = body} ->
        if compilation?(page, site) do
          {:ok, nil}
        else
          {:ok, page |> to_candidate(site, config[:max_chars]) |> put_links(page, body, config)}
        end

      {:ok, _body} ->
        {:error, :unexpected_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A page that yields a candidate also yields its links; one that does not
  # triggers no continuation request.
  defp put_links(nil, _page, _body, _config), do: nil

  defp put_links(candidate, %{"pageid" => pageid} = page, body, config) do
    Map.put(
      candidate,
      :links,
      extlinks(page) ++ more_extlinks(pageid, body, config, @max_link_requests)
    )
  end

  defp extlinks(page), do: for(%{"url" => url} <- page["extlinks"] || [], is_binary(url), do: url)

  # Follows `elcontinue` only: other modules (`templates` on Wikibooks) also
  # report a `continue`, which is not ours to follow.
  defp more_extlinks(pageid, %{"continue" => %{"elcontinue" => token}}, config, left)
       when left > 0 do
    params = [prop: "extlinks", ellimit: "max", pageids: pageid, elcontinue: token]

    case api_get(params, config) do
      {:ok, %{"query" => %{"pages" => [page | _rest]}} = body} ->
        extlinks(page) ++ more_extlinks(pageid, body, config, left - 1)

      other ->
        Logger.warning("link continuation for page #{pageid} failed: #{inspect(other)}")
        []
    end
  end

  defp more_extlinks(_pageid, _body, _config, _left), do: []

  @doc """
  The external links of a page fetched earlier, by the `pageid` in the
  document's `metadata`: one `prop=extlinks` request, plus continuations.
  `{:ok, []}` for a document without a page id or a page that is gone.
  """
  @spec links(%{required(:metadata) => map()}, site(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def links(%{metadata: %{"pageid" => pageid}}, site, opts) when is_integer(pageid) do
    config = config(site, opts)

    case api_get([prop: "extlinks", ellimit: "max", pageids: pageid], config) do
      {:ok, %{"query" => %{"pages" => [page | _rest]}} = body} ->
        {:ok, extlinks(page) ++ more_extlinks(pageid, body, config, @max_link_requests)}

      {:ok, _body} ->
        {:error, :unexpected_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def links(_document, _site, _opts), do: {:ok, []}

  @doc """
  The pages that the page stored as `document` links to on the same site,
  with their short descriptions: one `generator=links` request (redirects
  resolved), at most two for a page with more than 500 links. Red links,
  disambiguation pages, pages outside the site's `link_namespaces` and the
  page itself are left out. `{:ok, []}` for a document without a page id.
  """
  @spec link_candidates(%{required(:metadata) => map()}, site(), keyword()) ::
          {:ok, [Knowseek.Discovery.Source.link_candidate()]} | {:error, term()}
  def link_candidates(%{metadata: %{"pageid" => pageid}}, site, opts) when is_integer(pageid) do
    config = config(site, opts)
    namespaces = Map.get(site, :link_namespaces, [0])

    params = [
      generator: "links",
      pageids: pageid,
      gpllimit: "max",
      gplnamespace: Enum.join(namespaces, "|"),
      prop: "description|pageprops",
      ppprop: "disambiguation",
      redirects: 1
    ]

    with {:ok, body} <- api_get(params, config) do
      rest = more_linked_pages(params, body, config, @max_candidate_requests - 1)

      candidates =
        for page <- linked_pages(body) ++ rest,
            link_page?(page, namespaces, pageid),
            do: to_link_candidate(page, site)

      {:ok, Enum.uniq_by(candidates, & &1.page_id)}
    end
  end

  def link_candidates(_document, _site, _opts), do: {:ok, []}

  @doc """
  One page by its page id, as `discover/3` returns it: the same request, the
  same fields and the same `:links`. `{:ok, nil}` when the page yields no
  candidate (missing, a disambiguation page, no text, a compilation).
  """
  @spec page(integer(), site(), keyword()) ::
          {:ok, Knowseek.Discovery.Source.candidate() | nil} | {:error, term()}
  def page(page_id, site, opts) when is_integer(page_id),
    do: fetch_page(page_id, site, config(site, opts))

  defp linked_pages(%{"query" => %{"pages" => pages}}) when is_list(pages), do: pages
  defp linked_pages(_body), do: []

  # Follows `continue` once more when requests are left; a failed continuation
  # keeps the pages read so far.
  defp more_linked_pages(params, %{"continue" => %{} = continue}, config, left) when left > 0 do
    case api_get(params ++ Enum.to_list(continue), config) do
      {:ok, body} ->
        linked_pages(body) ++ more_linked_pages(params, body, config, left - 1)

      {:error, reason} ->
        Logger.warning("link candidate continuation failed: #{inspect(reason)}")
        []
    end
  end

  defp more_linked_pages(_params, _body, _config, _left), do: []

  # A real page of a wanted namespace that is not a disambiguation page and
  # not the source page itself. The namespace is checked again here: Wikibooks
  # answered with pages of other namespaces.
  defp link_page?(page, namespaces, source_pageid) do
    id = page["pageid"]

    is_integer(id) and id != source_pageid and page["missing"] != true and
      page["ns"] in namespaces and not is_map_key(page["pageprops"] || %{}, "disambiguation")
  end

  # MediaWiki answers `"description": ""` for a page whose description is blank.
  defp to_link_candidate(page, site) do
    %{
      page_id: page["pageid"],
      title: page["title"],
      description: if(page["description"] in [nil, ""], do: nil, else: page["description"]),
      url: page_url(site, page["pageid"])
    }
  end

  # `https://en.wikipedia.org/?curid=3973`: the scheme and host of the API URL.
  defp page_url(site, id) do
    uri = URI.parse(site.base_url)
    "#{uri.scheme}://#{uri.host}/?curid=#{id}"
  end

  # Asks for the main-namespace pages the page transcludes, enough of them to
  # tell a compilation.
  defp put_compilation_params(params, %{skip_compilations: true}) do
    params
    |> Keyword.update!(:prop, &(&1 <> "|templates"))
    |> Keyword.merge(tlnamespace: 0, tllimit: @compilation_min_pages)
  end

  defp put_compilation_params(params, _site), do: params

  defp compilation?(page, %{skip_compilations: true}),
    do: length(page["templates"] || []) >= @compilation_min_pages

  defp compilation?(_page, _site), do: false

  # Disambiguation pages only list links to other pages.
  defp to_candidate(%{"pageprops" => %{"disambiguation" => _}}, _site, _max_chars), do: nil

  # Missing pages and pages without text (for example a page deleted between
  # the search and the fetch) yield no candidate.
  defp to_candidate(%{"pageid" => pageid, "extract" => extract} = page, site, max_chars)
       when is_binary(extract) do
    case String.trim(extract) do
      "" ->
        nil

      body ->
        url = page["canonicalurl"] || page["fullurl"]

        %{
          url: url,
          title: page["title"],
          body: truncate(body, max_chars),
          metadata: %{"pageid" => pageid},
          license: site.license,
          attribution: %{url: url, credit: site.credit, authors: []},
          modified: true,
          share: "full"
        }
        |> put_monthly_views(page["pageviews"])
        |> put_source_updated_at(page["revisions"])
    end
  end

  defp to_candidate(_page, _site, _max_chars), do: nil

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
      |> Knowseek.Download.measure(config[:on_bytes])

    # A background caller of the shared Wikimedia slots (ADR 0027). Req's
    # retries, and their waits, keep the slot.
    case Knowseek.Wikimedia.run(:background, fn -> Req.get(request) end) do
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

  defp config(site, opts) do
    @defaults
    |> Keyword.put(:base_url, site.base_url)
    |> Keyword.merge(Application.get_env(:knowseek, site.config, []))
    |> Keyword.put(:on_bytes, opts[:on_bytes])
  end
end
