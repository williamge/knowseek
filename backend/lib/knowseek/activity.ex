defmodule Knowseek.Activity do
  @moduledoc """
  A local record of what Knowseek does, to judge whether crawling is worth it
  (#96, ADR 0031): every search, the bytes each discovery source downloads,
  and the numbers over both.

  Searches are written by `Knowseek.Activity.Recorder`, outside the request.
  A search with the same normalized query as one logged less than 120 seconds
  before is the same search (the web UI repeats a search while discovery
  runs): the row keeps its time and first coverage and takes the newest top
  results.
  """
  import Ecto.Query

  alias Knowseek.Activity.{NetworkUsage, Recorder, SearchHit, SearchRecord}
  alias Knowseek.{Documents, Repo}

  # The longest query that is stored.
  @max_query 500
  # Hits kept per search.
  @max_hits 10
  # `stats/1` looks at this many UTC days, today included.
  @window_days 30

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
          disk_bytes: non_neg_integer(),
          network: [%{day: Date.t(), source: String.t(), bytes: non_neg_integer()}],
          hit_share: %{background_pages: non_neg_integer(), hit_pages: non_neg_integer()}
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
  Called from discovery jobs, after the downloads. Option `:day` sets the day
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
  The numbers. `days` and `network` cover the last 30 UTC days (today
  included), newest first; a day with nothing is left out. Option `:today`
  sets the date (tests).
  """
  @spec stats(keyword()) :: stats()
  def stats(opts \\ []) do
    today = Keyword.get_lazy(opts, :today, &Date.utc_today/0)
    first_day = Date.add(today, 1 - @window_days)
    pages = Documents.count_by_origin()

    %{
      searches: %{total: Repo.aggregate(SearchRecord, :count), days: search_days(first_day)},
      pages: pages,
      disk_bytes: disk_bytes(),
      network: network(first_day),
      hit_share: %{background_pages: pages.background, hit_pages: hit_pages()}
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

  # The main database file. The WAL file (at most 64 MB after a checkpoint) is
  # not counted.
  defp disk_bytes do
    %{rows: [[bytes]]} =
      Repo.query!("SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()")

    bytes
  end

  defp hit_pages do
    Repo.one(from h in SearchHit, where: h.background, select: count(h.document_id, :distinct))
  end
end
