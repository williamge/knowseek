defmodule Knowseek.ActivityTest do
  use Knowseek.DataCase, async: false

  import ExUnit.CaptureLog

  alias Knowseek.Activity
  alias Knowseek.Activity.{NetworkUsage, Recorder, SearchHit, SearchRecord}
  alias Knowseek.Search.Hit

  @t0 ~U[2026-11-10 12:00:00Z]

  # Waits until the recorder has written what it was sent.
  defp drain, do: :sys.get_state(Recorder)

  defp hit(document, attrs \\ []) do
    struct!(
      Hit,
      Keyword.merge(
        [document_id: document.id, position: 0, origin: document.origin, passages: []],
        attrs
      )
    )
  end

  defp hits_of(search) do
    Repo.all(from h in SearchHit, where: h.search_id == ^search.id, order_by: h.rank)
  end

  describe "record_search/4" do
    test "returns :ok and the recorder stores the query, coverage and time" do
      document = document_fixture()

      assert :ok = Activity.record_search("tide pools", :partial, [hit(document)], now: @t0)
      drain()

      assert [%SearchRecord{query: "tide pools", coverage: "partial", inserted_at: @t0}] =
               Repo.all(SearchRecord)
    end

    test "keeps the first 10 hits, ranked from 1" do
      hits = for _ <- 1..12, do: hit(document_fixture())
      expected = hits |> Enum.take(10) |> Enum.map(& &1.document_id)

      search = logged_search_fixture(hits: hits)

      stored = hits_of(search)
      assert Enum.map(stored, & &1.rank) == Enum.to_list(1..10)
      assert Enum.map(stored, & &1.document_id) == expected
    end

    test "positions are the best chunk's, then the passages'" do
      document = document_fixture()

      search =
        logged_search_fixture(
          hits: [hit(document, position: 12, passages: [%{position: 3}, %{position: 7}])]
        )

      assert [%SearchHit{positions: [12, 3, 7]}] = hits_of(search)
    end

    test "background is true only for a hit whose origin is background" do
      background = document_fixture(origin: "background")
      searched = document_fixture(origin: "search")
      manual = document_fixture()

      search = logged_search_fixture(documents: [background, searched, manual])

      assert [true, false, false] == Enum.map(hits_of(search), & &1.background)
    end

    test "cuts a query over 500 characters" do
      Activity.record_search(String.duplicate("a", 600), :none, [])
      drain()

      assert [%SearchRecord{query: query}] = Repo.all(SearchRecord)
      assert query == String.duplicate("a", 500)
    end

    test "the same query within 120 seconds is one search: first time and coverage, new hits" do
      [first, second] = [document_fixture(), document_fixture()]

      Activity.record_search("kelp", :none, [hit(first)], now: @t0)
      Activity.record_search("kelp", :sufficient, [hit(second)], now: DateTime.add(@t0, 120))
      drain()

      assert [%SearchRecord{coverage: "none", inserted_at: @t0} = search] = Repo.all(SearchRecord)
      assert [%SearchHit{document_id: id}] = hits_of(search)
      assert id == second.id
    end

    test "the same query after 121 seconds, or another query, is a second search" do
      Activity.record_search("kelp", :none, [], now: @t0)
      Activity.record_search("kelp", :none, [], now: DateTime.add(@t0, 121))
      Activity.record_search("seaweed", :none, [], now: DateTime.add(@t0, 5))
      drain()

      assert Repo.aggregate(SearchRecord, :count) == 3
    end

    test "a failing write is logged, the recorder survives and stores the next search" do
      pid = Process.whereis(Recorder)

      log =
        capture_log(fn ->
          Activity.record_search("broken", :none, [%Hit{position: 0, origin: "manual"}])
          drain()
        end)

      assert log =~ "search not logged"
      assert Process.whereis(Recorder) == pid
      assert Repo.aggregate(SearchRecord, :count) == 0

      logged_search_fixture(query: "fine")
      assert Repo.aggregate(SearchRecord, :count) == 1
    end
  end

  describe "clear_searches/0" do
    test "returns the count and removes the searches and their hits" do
      document = document_fixture()
      logged_search_fixture(documents: [document])
      logged_search_fixture(documents: [document])

      assert {:ok, 2} = Activity.clear_searches()
      assert Repo.aggregate(SearchRecord, :count) == 0
      assert Repo.aggregate(SearchHit, :count) == 0
    end

    test "runs after a search cast just before it" do
      Activity.record_search("just before", :none, [])

      assert {:ok, 1} = Activity.clear_searches()
      assert Repo.aggregate(SearchRecord, :count) == 0
    end
  end

  describe "record_bytes/3" do
    test "adds up per day and source, and keeps days and sources apart" do
      today = ~D[2026-11-10]

      :ok = Activity.record_bytes("wikipedia", 100, day: today)
      :ok = Activity.record_bytes("wikipedia", 50, day: today)
      :ok = Activity.record_bytes("wikibooks", 7, day: today)
      :ok = Activity.record_bytes("wikipedia", 1, day: Date.add(today, -1))

      rows = Repo.all(from n in NetworkUsage, select: {n.day, n.source, n.bytes})

      assert Enum.sort(rows) ==
               Enum.sort([
                 {today, "wikipedia", 150},
                 {today, "wikibooks", 7},
                 {Date.add(today, -1), "wikipedia", 1}
               ])
    end

    test "counts today (UTC) by default" do
      :ok = Activity.record_bytes("wikipedia", 10)
      assert [%NetworkUsage{day: day, bytes: 10}] = Repo.all(NetworkUsage)
      assert day == Date.utc_today()
    end

    test "writes nothing for zero" do
      assert :ok = Activity.record_bytes("wikipedia", 0)
      assert Repo.aggregate(NetworkUsage, :count) == 0
    end
  end

  describe "stats/1" do
    @today ~D[2026-11-10]

    defp stats, do: Activity.stats(today: @today)

    test "is empty on an empty database, with a disk size" do
      assert %{
               searches: %{total: 0, days: []},
               pages: %{search: 0, background: 0, manual: 0},
               network: [],
               hit_share: %{background_pages: 0, hit_pages: 0}
             } = stats = stats()

      assert stats.disk_bytes > 0
    end

    test "counts searches, pivots the last 30 days by coverage, newest first" do
      at = fn date, time -> DateTime.new!(date, time, "Etc/UTC") end

      logged_search_fixture(query: "a", coverage: :none, now: at.(@today, ~T[08:00:00]))
      logged_search_fixture(query: "b", coverage: :none, now: at.(@today, ~T[09:00:00]))
      logged_search_fixture(query: "c", coverage: :sufficient, now: at.(@today, ~T[23:59:59]))

      logged_search_fixture(
        query: "d",
        coverage: :partial,
        now: at.(~D[2026-10-12], ~T[00:00:00])
      )

      # 31 days old: outside `days`, inside `total`.
      logged_search_fixture(query: "e", coverage: :none, now: at.(~D[2026-10-10], ~T[12:00:00]))

      assert %{searches: %{total: 5, days: days}} = stats()

      assert days == [
               %{day: @today, sufficient: 1, partial: 0, none: 2},
               %{day: ~D[2026-10-12], sufficient: 0, partial: 1, none: 0}
             ]
    end

    test "pages counts documents by origin" do
      document_fixture(origin: "search", origin_query: "q")
      document_fixture(origin: "search")
      document_fixture(origin: "background")
      document_fixture()

      assert %{pages: %{search: 2, background: 1, manual: 1}} = stats()
    end

    test "network covers the window, newest day first, then by source" do
      Activity.record_bytes("wikipedia", 10, day: @today)
      Activity.record_bytes("wikibooks", 20, day: @today)
      Activity.record_bytes("wikipedia", 30, day: ~D[2026-10-12])
      Activity.record_bytes("wikipedia", 40, day: ~D[2026-10-11])

      assert %{network: network} = stats()

      assert network == [
               %{day: @today, source: "wikibooks", bytes: 20},
               %{day: @today, source: "wikipedia", bytes: 10},
               %{day: ~D[2026-10-12], source: "wikipedia", bytes: 30}
             ]
    end

    test "hit share counts a background document once, and not a search document" do
      background = document_fixture(origin: "background")
      _unseen = document_fixture(origin: "background")
      searched = document_fixture(origin: "search")

      logged_search_fixture(query: "one", documents: [background, searched])
      logged_search_fixture(query: "two", documents: [background])

      assert %{hit_share: %{background_pages: 2, hit_pages: 1}} = stats()
    end
  end

  describe "result_pages/1" do
    test "lists the appearances of a page with query, rank and single" do
      a = document_fixture()
      b = document_fixture()
      logged_search_fixture(query: "pair", documents: [a, b], now: @t0)
      logged_search_fixture(query: "solo", documents: [b], now: DateTime.add(@t0, 300))

      pages = Activity.result_pages(now: DateTime.add(@t0, 600))

      assert [%{query: "pair", rank: 1, single: false}] = pages[a.id]

      assert [
               %{query: "solo", rank: 1, single: true},
               %{query: "pair", rank: 2, single: false}
             ] = pages[b.id]
    end

    test "leaves out background hits" do
      background = document_fixture(origin: "background")
      searched = document_fixture()
      logged_search_fixture(documents: [background, searched], now: @t0)

      pages = Activity.result_pages(now: @t0)

      refute Map.has_key?(pages, background.id)
      assert Map.has_key?(pages, searched.id)
    end

    test "leaves out searches older than the window, and :days widens it" do
      doc = document_fixture()
      logged_search_fixture(documents: [doc], now: @t0)
      later = DateTime.add(@t0, 40 * 86_400)

      assert Activity.result_pages(now: later) == %{}
      assert %{} = pages = Activity.result_pages(now: later, days: 60)
      assert Map.has_key?(pages, doc.id)
    end

    test "is empty without searches" do
      assert Activity.result_pages(now: @t0) == %{}
    end
  end

  describe "last_search_at/0" do
    test "is nil without searches" do
      assert Activity.last_search_at() == nil
    end

    test "is the time of the newest search" do
      logged_search_fixture(query: "old", now: @t0)
      logged_search_fixture(query: "new", now: DateTime.add(@t0, 3600))

      assert Activity.last_search_at() == DateTime.add(@t0, 3600)
    end

    test "a repeat within 120 seconds keeps the first time" do
      logged_search_fixture(query: "kelp", now: @t0)
      logged_search_fixture(query: "kelp", now: DateTime.add(@t0, 60))

      assert Activity.last_search_at() == @t0
    end
  end
end
