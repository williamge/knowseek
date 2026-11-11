defmodule Knowseek.Discovery do
  @moduledoc """
  Seeks new data for a query when the index does not cover it.

  `request/1` enqueues a `Knowseek.Discovery.SeekWorker` job. The job calls
  `run/2`, which asks every configured `Knowseek.Discovery.Source` for
  candidates and ingests them.

  A candidate's `:links` never reach `Knowseek.Documents.ingest/1`: after the
  document is stored, the links to hosts off the allowlist are logged in
  `blocked_links` (#88, ADR 0032). `allowed?/1` is the gate a crawler calls
  before it fetches a URL. `backfill_links/0` logs the links of the pages
  already indexed. `link_candidates/1` lists the pages a stored page links
  to, for the background crawl (#89, ADR 0033): `Knowseek.Crawl` reaches a
  source only through it.

  Requests for the same normalized query within one hour are deduplicated.
  The insert runs in a transaction: Oban's SQLite engine checks uniqueness
  and inserts in two statements, and only the transaction's write lock
  (taken up front, ADR 0030) keeps two requests from both inserting.

  Each ingested candidate carries its origin (#96, ADR 0031): `origin:
  "search"` and the normalized query as `origin_query`. A source never sets
  them. The bytes a source downloads are counted in memory while it runs (the
  `:on_bytes` option of `Knowseek.Discovery.Source.discover/2`) and recorded
  with `Knowseek.Activity.record_bytes/2` after it returned, also when it
  failed.
  """
  require Logger

  import Ecto.Query

  alias Knowseek.Activity
  alias Knowseek.Discovery.{Allowlist, BlockedLink, LinkBackfillWorker, SeekWorker}
  alias Knowseek.Documents
  alias Knowseek.Repo

  @type summary :: %{ingested: non_neg_integer(), failed: non_neg_integer()}

  @spec request(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def request(query) when is_binary(query) do
    job = SeekWorker.new(%{"query" => normalize(query)})
    Repo.transact(fn -> Oban.insert(job) end)
  end

  @doc "Runs every source for `query` and ingests the results."
  @spec run(String.t(), keyword()) :: {:ok, summary()}
  def run(query, opts \\ []) do
    sources = Keyword.get(opts, :sources, sources())

    summary =
      sources
      |> Enum.flat_map(&discover(&1, query, opts))
      |> Enum.reduce(%{ingested: 0, failed: 0}, fn candidate, acc ->
        case ingest(candidate) do
          {:ok, _document} ->
            Map.update!(acc, :ingested, &(&1 + 1))

          {:error, reason} ->
            Logger.warning("discovery ingest failed: #{inspect(reason)}")
            Map.update!(acc, :failed, &(&1 + 1))
        end
      end)

    {:ok, summary}
  end

  @spec sources() :: [module()]
  def sources, do: Application.get_env(:knowseek, __MODULE__, []) |> Keyword.get(:sources, [])

  @doc "Lowercases and collapses whitespace so equivalent queries share one job."
  @spec normalize(String.t()) :: String.t()
  def normalize(query), do: query |> String.downcase() |> String.split() |> Enum.join(" ")

  # A query longer than this is cut in `documents.origin_query`.
  @max_origin_query 500

  @doc "The allowed hosts from config: the only hosts a crawler may fetch from."
  @spec allowed_hosts() :: [String.t()]
  def allowed_hosts, do: Allowlist.hosts()

  @doc "Whether a crawler may fetch `url`: a web link to a host on the allowlist. The gate #89 calls before any fetch."
  @spec allowed?(String.t()) :: boolean()
  def allowed?(url), do: Allowlist.allowed?(url)

  @doc """
  Logs the links of the page stored as `document_id` that point to hosts off
  the allowlist. Links that are no web links, and links to allowed hosts, are
  dropped. Returns the number of blocked links in `urls`.

  A link already logged for the page gets `times_seen + 1`. With
  `count: false` (the backfill) it is left alone, so the backfill can run twice.
  """
  @spec record_links(Ecto.UUID.t(), [String.t()], keyword()) :: {:ok, non_neg_integer()}
  def record_links(document_id, urls, opts \\ []) do
    now = DateTime.utc_now(:second)
    on_conflict = if Keyword.get(opts, :count, true), do: [inc: [times_seen: 1]], else: :nothing

    rows =
      urls
      |> blocked_links()
      |> Enum.map(fn %{url: url, host: host} ->
        %{document_id: document_id, url: url, host: host, first_seen_at: now, times_seen: 1}
      end)

    insert_blocked(rows, on_conflict)
    {:ok, length(rows)}
  end

  # The links to hosts off the allowlist, once each.
  defp blocked_links(urls) do
    hosts = Allowlist.hosts()

    for url <- urls,
        {:ok, %{host: host} = link} <- [Allowlist.parse(url)],
        host not in hosts,
        uniq: true,
        do: link
  end

  defp insert_blocked([], _on_conflict), do: :ok

  defp insert_blocked(rows, on_conflict) do
    {:ok, :ok} =
      Repo.transact(fn ->
        for chunk <- Enum.chunk_every(rows, 500) do
          Repo.insert_all(BlockedLink, chunk,
            on_conflict: on_conflict,
            conflict_target: [:document_id, :url]
          )
        end

        {:ok, :ok}
      end)

    :ok
  end

  @type blocked_domain :: %{
          host: String.t(),
          links: non_neg_integer(),
          pages: non_neg_integer(),
          times_seen: non_neg_integer(),
          first_seen_at: DateTime.t(),
          example_url: String.t()
        }

  @doc "The blocked-link log by domain: most linking pages first, then most links, then host. `:limit` domains (default 200), and the totals over the whole log."
  @spec blocked_domains(keyword()) :: %{
          domains: [blocked_domain()],
          total_domains: non_neg_integer(),
          total_links: non_neg_integer()
        }
  def blocked_domains(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    domains =
      Repo.all(
        from b in BlockedLink,
          group_by: b.host,
          order_by: [
            desc: count(b.document_id, :distinct),
            desc: count(b.url, :distinct),
            asc: b.host
          ],
          limit: ^limit,
          select: %{
            host: b.host,
            links: count(b.url, :distinct),
            pages: count(b.document_id, :distinct),
            times_seen: sum(b.times_seen),
            first_seen_at: type(min(b.first_seen_at), :utc_datetime),
            example_url: min(b.url)
          }
      )

    totals =
      Repo.one(
        from b in BlockedLink,
          select: %{
            total_domains: count(b.host, :distinct),
            total_links: count(b.url, :distinct)
          }
      )

    Map.put(totals, :domains, domains)
  end

  @doc "Enqueues one `LinkBackfillWorker` job per document of a configured source that implements `links/2`. Returns the number of documents."
  @spec backfill_links() :: {:ok, non_neg_integer()}
  def backfill_links do
    names = for source <- sources(), links_source?(source), do: source.name()
    ids = Documents.ids_by_source(names)

    ids
    |> Enum.with_index()
    |> Enum.chunk_every(100)
    |> Enum.each(&enqueue_backfill/1)

    {:ok, length(ids)}
  end

  # One transaction a chunk: it is needed for uniqueness on the Lite engine
  # (as in `request/1`). Two jobs a second is 120 requests a minute, under
  # Wikimedia's 200 a minute, which the slots of ADR 0027 do not cover.
  defp enqueue_backfill(chunk) do
    {:ok, _jobs} =
      Repo.transact(fn ->
        jobs =
          for {id, index} <- chunk do
            %{"document_id" => id}
            |> LinkBackfillWorker.new(schedule_in: 1 + div(index, 2))
            |> Oban.insert!()
          end

        {:ok, jobs}
      end)
  end

  @doc "Fetches the links of one stored document from its source and logs the blocked ones without counting. What `LinkBackfillWorker` runs."
  @spec fetch_links(Ecto.UUID.t()) :: :ok | {:error, term()}
  def fetch_links(id) do
    with %{} = document <- Documents.get_document(id),
         source when source != nil <-
           Enum.find(sources(), &(links_source?(&1) and &1.name() == document.source)),
         {:ok, urls} <-
           counting_bytes(source, fn on_bytes ->
             source.links(document, on_bytes: on_bytes)
           end) do
      {:ok, _blocked} = record_links(document.id, urls, count: false)
      :ok
    else
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The pages `document` links to on its own site, from its source, for the
  background crawl (#89, ADR 0033). `{:ok, []}` when the document's source
  has no `link_candidates/2` or the document's URL is off the allowlist.
  Links whose URL is off the allowlist are dropped. The downloaded bytes are
  recorded for the source.
  """
  @spec link_candidates(Documents.Document.t()) ::
          {:ok, [Knowseek.Discovery.Source.link_candidate()]} | {:error, term()}
  def link_candidates(%Documents.Document{} = document) do
    with source when source != nil <- crawl_source(document.source),
         true <- allowed?(document.url),
         {:ok, links} <-
           counting_bytes(source, fn on_bytes ->
             source.link_candidates(document, on_bytes: on_bytes)
           end) do
      {:ok, Enum.filter(links, &allowed?(&1.url))}
    else
      {:error, reason} -> {:error, reason}
      _no_source_or_not_allowed -> {:ok, []}
    end
  end

  # The configured source with this name that can list a page's links.
  defp crawl_source(name) do
    Enum.find(sources(), &(crawl_source?(&1) and &1.name() == name))
  end

  defp crawl_source?(source),
    do: Code.ensure_loaded?(source) and function_exported?(source, :link_candidates, 2)

  defp links_source?(source),
    do: Code.ensure_loaded?(source) and function_exported?(source, :links, 2)

  # The candidate's links never reach `Documents.ingest/1`. They are logged
  # after the document is stored, in a transaction of their own (rules 2 and 5).
  defp ingest(candidate) do
    {links, attrs} = Map.pop(candidate, :links, [])

    with {:ok, document} <- Documents.ingest(attrs) do
      {:ok, _blocked} = record_links(document.id, links)
      {:ok, document}
    end
  end

  defp discover(source, query, opts) do
    result =
      counting_bytes(source, fn on_bytes ->
        source.discover(query, Keyword.put(opts, :on_bytes, on_bytes))
      end)

    case result do
      {:ok, candidates} ->
        # Search-time discovery is the only caller today; #89 adds "background".
        origin = %{
          source: source.name(),
          origin: "search",
          origin_query: String.slice(query, 0, @max_origin_query)
        }

        Enum.map(candidates, &Map.merge(&1, origin))

      {:error, reason} ->
        Logger.warning("discovery source #{inspect(source)} failed: #{inspect(reason)}")
        []
    end
  end

  # Runs `fun` with a function that counts downloaded bytes, then records the
  # total for `source`: one write, after the external calls (rules 3 and 5).
  defp counting_bytes(source, fun) do
    counter = :counters.new(1, [])
    result = fun.(fn bytes -> :counters.add(counter, 1, bytes) end)
    Activity.record_bytes(source.name(), :counters.get(counter, 1))
    result
  end
end
