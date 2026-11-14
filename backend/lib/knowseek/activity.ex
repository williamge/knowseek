defmodule Knowseek.Activity do
  @moduledoc """
  A local record of what Knowseek does, to judge whether crawling is worth it
  (#96, ADR 0031): every search, the bytes each source downloads, and the
  numbers over both.

  Searches are written by `Knowseek.Activity.Recorder`, outside the request.
  A search with the same normalized query as one logged less than 120 seconds
  before is the same search (the web UI repeats a search while discovery
  runs): the row keeps its time and first coverage and takes the newest top
  results.

  `stats/1` also counts **gain** (#89, ADR 0033), from this log alone: a
  search counts when at least one of its logged results is a background page
  and fewer than `min_strong_hits` are not. `pages` are the distinct
  background pages of those searches, `searches` the searches themselves in
  the last 30 days.

  **Budgets** (#90, ADR 0034): `budget/1` reads the disk the database takes,
  the bytes downloaded today (UTC) and the free disk space, and `hold/2` says
  whether background work or a typed search's fetching may start. Discovery
  jobs record their bytes with `record_bytes/3`; downloads that happen outside
  a job (Wikidata, the card sources, a hosted embedding service) hand theirs
  to the recorder with `count_bytes/2`.
  """
  import Ecto.Query

  alias Knowseek.Activity.{Budget, NetworkUsage, Recorder, SearchHit, SearchRecord}
  alias Knowseek.{Documents, Repo}

  require Logger

  # The longest query that is stored.
  @max_query 500
  # Hits kept per search.
  @max_hits 10
  # `stats/1` looks at this many UTC days, today included.
  @window_days 30

  @type level :: :ok | :near | :full

  @type budget :: %{
          disk: %{used: non_neg_integer(), limit: non_neg_integer(), state: level()},
          network: %{used: non_neg_integer(), limit: non_neg_integer(), state: level()},
          free_disk: %{bytes: non_neg_integer() | nil, floor: non_neg_integer(), low: boolean()},
          background_share: float()
        }

  @type hold :: :disk | :network | :free_disk

  @type stats :: %{
          searches: %{
            total: non_neg_integer(),
            days: [
              %{
                day: Date.t(),
                sufficient: non_neg_integer(),
                partial: non_neg_integer(),
                none: non_neg_integer()
              }
            ]
          },
          pages: %{
            search: non_neg_integer(),
            background: non_neg_integer(),
            manual: non_neg_integer()
          },
          budget: budget(),
          passages: non_neg_integer(),
          network: [%{day: Date.t(), source: String.t(), bytes: non_neg_integer()}],
          hit_share: %{background_pages: non_neg_integer(), hit_pages: non_neg_integer()},
          gain: %{
            pages: non_neg_integer(),
            searches: non_neg_integer(),
            window_searches: non_neg_integer()
          }
        }

  @doc """
  Hands a search to the log and returns at once. The row is written by
  `Knowseek.Activity.Recorder`, outside the caller: the caller never takes the
  database's write lock. `query` is already normalized. Only the first 10
  `hits` are kept. Option `:now` sets the time (tests).
  """
  @spec record_search(
          String.t(),
          Knowseek.Search.Coverage.t(),
          [Knowseek.Search.Hit.t()],
          keyword()
        ) ::
          :ok
  def record_search(query, coverage, hits, opts \\ []) do
    record = %{
      query: String.slice(query, 0, @max_query),
      coverage: Atom.to_string(coverage),
      at: Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now(:second) end),
      hits:
        hits
        |> Enum.take(@max_hits)
        |> Enum.with_index(1)
        |> Enum.map(fn {hit, rank} ->
          %{
            rank: rank,
            document_id: hit.document_id,
            positions: [hit.position | Enum.map(hit.passages, & &1.position)],
            background: hit.origin == "background"
          }
        end)
    }

    GenServer.cast(Recorder, {:search, record})
  end

  @doc """
  Deletes every logged search and its hits, after the searches the recorder
  still holds. Returns how many searches were deleted. This call waits for the
  write lock: it is an explicit user action, not a search.
  """
  @spec clear_searches() :: {:ok, non_neg_integer()}
  def clear_searches, do: GenServer.call(Recorder, :clear)

  @doc """
  Adds `bytes` to today's (UTC) count for `source`. Zero writes nothing.
  Called from discovery jobs after their downloads, and by
  `Knowseek.Activity.Recorder` for `count_bytes/2`. Option `:day` sets the day
  (tests).
  """
  @spec record_bytes(String.t(), non_neg_integer(), keyword()) :: :ok
  def record_bytes(source, bytes, opts \\ [])
  def record_bytes(_source, 0, _opts), do: :ok

  def record_bytes(source, bytes, opts) when is_integer(bytes) and bytes > 0 do
    day = Keyword.get_lazy(opts, :day, &Date.utc_today/0)

    Repo.insert_all(NetworkUsage, [%{day: day, source: source, bytes: bytes}],
      on_conflict: [inc: [bytes: bytes]],
      conflict_target: [:day, :source]
    )

    :ok
  end

  @doc """
  Hands a byte count to the recorder and returns at once: for downloads that
  happen outside a discovery job (Wikidata, cards, a hosted embedding
  service). Best effort, like the search log. Zero sends nothing.
  """
  @spec count_bytes(String.t(), non_neg_integer()) :: :ok
  def count_bytes(_source, 0), do: :ok

  def count_bytes(source, bytes) when is_integer(bytes) and bytes > 0,
    do: GenServer.cast(Recorder, {:bytes, source, bytes})

  @doc """
  The two budgets and the free disk space, as they are now (#90, ADR 0034).
  Disk: the database file's pages in use plus its write-ahead log. Network:
  the bytes counted today (UTC), all sources. Only reads. Free disk space is
  `low` when it is under the floor **or cannot be read** (unreadable is not
  safe); a floor of 0 turns the check off. Options: `:today` (tests),
  `:free_disk_bytes` (tests: the reading, `nil` for an unreadable one),
  `free_disk: false` (make no free-disk reading: `bytes` is `nil` and `low`
  is `false`).
  """
  @spec budget(keyword()) :: budget()
  def budget(opts \\ []) do
    config = Application.fetch_env!(:knowseek, __MODULE__)
    today = Keyword.get_lazy(opts, :today, &Date.utc_today/0)
    share = config[:background_share]
    disk = %{used: disk_used(), limit: config[:disk_budget_bytes]}
    network = %{used: network_used(today), limit: config[:network_budget_bytes]}

    %{
      disk: Map.put(disk, :state, Budget.level(disk.used, disk.limit, share)),
      network: Map.put(network, :state, Budget.level(network.used, network.limit, share)),
      free_disk: free_disk(config[:min_free_disk_bytes], opts),
      background_share: share
    }
  end

  @doc """
  Why work of this kind must not start now, or `nil`: `:background` for the
  crawl and the link backfill, `:search` for the fetches of a typed search
  (which makes no free-disk reading, so it is safe in the request path).
  Options as `budget/1`.
  """
  @spec hold(:background | :search, keyword()) :: hold() | nil
  def hold(kind, opts \\ [])
  def hold(:background, opts), do: Budget.hold(:background, budget(opts))
  def hold(:search, opts), do: Budget.hold(:search, budget([free_disk: false] ++ opts))

  # The pages in use plus the write-ahead log. Free pages are reused by the
  # next write, so they are not used (ADR 0034).
  defp disk_used do
    %{rows: [[pages_bytes]]} =
      Repo.query!(
        "SELECT (page_count - freelist_count) * page_size FROM pragma_page_count(), pragma_freelist_count(), pragma_page_size()"
      )

    case File.stat(Repo.config()[:database] <> "-wal") do
      {:ok, %File.Stat{size: wal}} -> pages_bytes + wal
      {:error, _reason} -> pages_bytes
    end
  end

  defp network_used(today) do
    Repo.one(from n in NetworkUsage, where: n.day == ^today, select: coalesce(sum(n.bytes), 0))
  end

  defp free_disk(floor, opts) do
    if floor == 0 or Keyword.get(opts, :free_disk) == false do
      %{bytes: nil, floor: floor, low: false}
    else
      bytes =
        case Keyword.fetch(opts, :free_disk_bytes) do
          {:ok, bytes} -> bytes
          :error -> free_disk_bytes()
        end

      %{bytes: bytes, floor: floor, low: is_nil(bytes) or bytes < floor}
    end
  end

  # The free space of the volume that holds the database, from disksup
  # (os_mon). `nil` when it cannot be read: unknown is not safe, so it holds
  # background work back like a low reading does.
  defp free_disk_bytes do
    dir = Repo.config()[:database] |> Path.expand() |> Path.dirname() |> String.to_charlist()

    case :disksup.get_disk_info(dir) do
      [{_mount, total_kib, available_kib, _capacity}] when total_kib > 0 -> available_kib * 1024
      _unknown -> unreadable()
    end
  catch
    :exit, _reason -> unreadable()
  end

  defp unreadable do
    # One warning per start: background work asks every minute.
    unless :persistent_term.get({__MODULE__, :warned}, false) do
      :persistent_term.put({__MODULE__, :warned}, true)

      Logger.warning(
        "budget: free disk space cannot be read; background work is held back until it can"
      )
    end

    nil
  end

  @doc """
  The numbers. `days` and `network` cover the last 30 UTC days (today
  included), newest first; a day with nothing is left out. `budget` is
  `budget/1`; `passages` counts the stored chunks. Option `:today` sets the
  date (tests).
  """
  @spec stats(keyword()) :: stats()
  def stats(opts \\ []) do
    today = Keyword.get_lazy(opts, :today, &Date.utc_today/0)
    first_day = Date.add(today, 1 - @window_days)
    pages = Documents.count_by_origin()

    %{
      searches: %{total: Repo.aggregate(SearchRecord, :count), days: search_days(first_day)},
      pages: pages,
      budget: budget(today: today),
      passages: Documents.count_chunks(),
      network: network(first_day),
      hit_share: %{background_pages: pages.background, hit_pages: hit_pages()},
      gain: gain(first_day)
    }
  end

  defp search_days(first_day) do
    since = DateTime.new!(first_day, ~T[00:00:00], "Etc/UTC")

    Repo.all(
      from s in SearchRecord,
        where: s.inserted_at >= ^since,
        group_by: [fragment("date(?)", s.inserted_at), s.coverage],
        select: {fragment("date(?)", s.inserted_at), s.coverage, count()}
    )
    |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})
    |> Enum.map(fn {day, counts} ->
      counts = Map.new(counts)

      %{
        day: Date.from_iso8601!(day),
        sufficient: Map.get(counts, "sufficient", 0),
        partial: Map.get(counts, "partial", 0),
        none: Map.get(counts, "none", 0)
      }
    end)
    |> Enum.sort_by(& &1.day, {:desc, Date})
  end

  defp network(first_day) do
    Repo.all(
      from n in NetworkUsage,
        where: n.day >= ^first_day,
        order_by: [desc: n.day, asc: n.source],
        select: %{day: n.day, source: n.source, bytes: n.bytes}
    )
  end

  @typedoc "One time a page was in the logged results of a search."
  @type appearance :: %{
          query: String.t(),
          rank: pos_integer(),
          single: boolean(),
          at: DateTime.t()
        }

  @doc """
  The pages in the logged results of the searches of the last `:days`
  (default 30), each with its appearances, newest first. Background pages
  are left out (a hit whose `background` is true). `single` is true when the
  search had exactly one result. Option `:now` sets the time (tests). The
  background crawl (#89) takes its source pages from here.
  """
  @spec result_pages(keyword()) :: %{Ecto.UUID.t() => [appearance()]}
  def result_pages(opts \\ []) do
    days = Keyword.get(opts, :days, @window_days)
    now = Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now(:second) end)
    since = DateTime.add(now, -days * 86_400, :second)

    Repo.all(
      from h in SearchHit,
        join: s in SearchRecord,
        on: s.id == h.search_id,
        where: s.inserted_at >= ^since and not h.background,
        order_by: [desc: s.inserted_at, desc: s.id, asc: h.rank],
        select: {
          h.document_id,
          %{query: s.query, rank: h.rank, at: s.inserted_at},
          fragment("(SELECT count(*) FROM search_hits AS a WHERE a.search_id = ?)", s.id)
        }
    )
    |> Enum.group_by(
      fn {document_id, _appearance, _hits} -> document_id end,
      fn {_document_id, appearance, hits} -> Map.put(appearance, :single, hits == 1) end
    )
  end

  @doc """
  When the newest logged search was made, or `nil`. A repeat within 120
  seconds keeps the first time.
  """
  @spec last_search_at() :: DateTime.t() | nil
  def last_search_at do
    Repo.one(
      from s in SearchRecord, order_by: [desc: s.inserted_at], limit: 1, select: s.inserted_at
    )
  end

  defp hit_pages do
    Repo.one(from h in SearchHit, where: h.background, select: count(h.document_id, :distinct))
  end

  @doc "Which of `document_ids` appeared in the logged results of a search."
  @spec hit_documents([Ecto.UUID.t()]) :: MapSet.t(Ecto.UUID.t())
  def hit_documents([]), do: MapSet.new()

  def hit_documents(document_ids) do
    document_ids
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from h in SearchHit, where: h.document_id in ^chunk, distinct: true, select: h.document_id
      )
    end)
    |> MapSet.new()
  end

  # Gain (#89, ADR 0033): a search counts when at least one of its logged
  # results is a background page and fewer than `min_strong_hits` are not:
  # without the background page, coverage would not have been `sufficient`.
  # The hit's `background` flag was written at search time, so such a search
  # was made after the fetch.
  defp gain(first_day) do
    since = DateTime.new!(first_day, ~T[00:00:00], "Etc/UTC")
    min_strong = Application.fetch_env!(:knowseek, Knowseek.Search)[:min_strong_hits]

    counted =
      from h in SearchHit,
        group_by: h.search_id,
        having:
          fragment("sum(?) > 0", h.background) and
            fragment("sum(NOT ?) < ?", h.background, ^min_strong),
        select: h.search_id

    %{
      pages:
        Repo.one(
          from h in SearchHit,
            where: h.background and h.search_id in subquery(counted),
            select: count(h.document_id, :distinct)
        ),
      searches:
        Repo.one(
          from s in SearchRecord,
            where: s.inserted_at >= ^since and s.id in subquery(counted),
            select: count()
        ),
      window_searches:
        Repo.one(from s in SearchRecord, where: s.inserted_at >= ^since, select: count())
    }
  end
end
