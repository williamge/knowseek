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

  describe "count_bytes/2" do
    test "the recorder adds the bytes to today's count for the source" do
      assert :ok = Activity.count_bytes("wikidata", 120)
      assert :ok = Activity.count_bytes("wikidata", 80)
      assert :ok = Activity.count_bytes("edgar", 5)
      _ = drain()

      today = Date.utc_today()

      assert Enum.sort(Repo.all(from n in NetworkUsage, select: {n.day, n.source, n.bytes})) ==
               [{today, "edgar", 5}, {today, "wikidata", 200}]
    end

    test "zero sends nothing" do
      assert :ok = Activity.count_bytes("wikidata", 0)
      _ = drain()

      assert Repo.aggregate(NetworkUsage, :count) == 0
    end
  end

  # Sets budget options for the test and restores the config after it.
  defp put_budget(attrs) do
    config = Application.fetch_env!(:knowseek, Activity)
    on_exit(fn -> Application.put_env(:knowseek, Activity, config) end)
    Application.put_env(:knowseek, Activity, Keyword.merge(config, attrs))
  end

  describe "budget/1" do
    @budget_day ~D[2026-11-10]

    test "limits and share come from the config" do
      put_budget(disk_budget_bytes: 123, network_budget_bytes: 456, background_share: 0.5)

      assert %{disk: %{limit: 123}, network: %{limit: 456}, background_share: 0.5} =
               Activity.budget()
    end

    test "disk used is positive and grows after an ingest" do
      before = Activity.budget().disk.used
      assert before > 0

      for i <- 1..10, do: document_fixture(body: long_body("grow #{i}"))

      assert Activity.budget().disk.used > before
    end

    test "disk state follows the level of used against the limit" do
      used = Activity.budget().disk.used

      put_budget(disk_budget_bytes: used * 100)
      assert Activity.budget().disk.state == :ok

      put_budget(disk_budget_bytes: 0)
      assert Activity.budget().disk.state == :full
    end

    test "network used is the sum of today's rows of all sources, not yesterday's" do
      Activity.record_bytes("wikipedia", 100, day: @budget_day)
      Activity.record_bytes("wikidata", 20, day: @budget_day)
      Activity.record_bytes("wikipedia", 5_000, day: Date.add(@budget_day, -1))

      assert %{network: %{used: 120}} = Activity.budget(today: @budget_day)
      assert %{network: %{used: 0}} = Activity.budget(today: Date.add(@budget_day, 1))
    end

    test "network state is :ok, :near at the share and :full at the limit" do
      put_budget(network_budget_bytes: 1_000, background_share: 0.9)

      assert %{network: %{state: :ok}} = Activity.budget(today: @budget_day)

      Activity.record_bytes("wikipedia", 900, day: @budget_day)
      assert %{network: %{state: :near}} = Activity.budget(today: @budget_day)

      Activity.record_bytes("wikipedia", 100, day: @budget_day)
      assert %{network: %{state: :full}} = Activity.budget(today: @budget_day)
    end

    test "a free disk reading under the floor is low, at the floor it is not" do
      put_budget(min_free_disk_bytes: 1_000)

      assert %{free_disk: %{bytes: 999, floor: 1_000, low: true}} =
               Activity.budget(free_disk_bytes: 999)

      assert %{free_disk: %{bytes: 1_000, floor: 1_000, low: false}} =
               Activity.budget(free_disk_bytes: 1_000)
    end

    test "a floor of 0 turns the check off: no reading, not low" do
      put_budget(min_free_disk_bytes: 0)

      assert %{free_disk: %{bytes: nil, floor: 0, low: false}} =
               Activity.budget(free_disk_bytes: 5)
    end

    test "free_disk: false makes no reading and is not low" do
      put_budget(min_free_disk_bytes: 1_000)

      assert %{free_disk: %{bytes: nil, floor: 1_000, low: false}} =
               Activity.budget(free_disk: false, free_disk_bytes: 5)
    end

    test "an unreadable free disk (nil) with a floor above 0 is low" do
      put_budget(min_free_disk_bytes: 1_000)

      assert %{free_disk: %{bytes: nil, floor: 1_000, low: true}} =
               Activity.budget(free_disk_bytes: nil)
    end

    test "reads the real free disk space when no reading is given" do
      put_budget(min_free_disk_bytes: 1_000_000_000)

      # An unreadable space logs one warning per start.
      capture_log(fn ->
        assert %{free_disk: %{bytes: bytes, floor: 1_000_000_000, low: low}} = Activity.budget()

        assert is_integer(bytes) or is_nil(bytes)
        assert low == (is_nil(bytes) or bytes < 1_000_000_000)
      end)
    end
  end

  describe "hold/2" do
    test "is nil with every budget well under its limit" do
      assert Activity.hold(:background) == nil
      assert Activity.hold(:search) == nil
    end

    test "a disk budget of 0 holds both kinds" do
      put_budget(disk_budget_bytes: 0)

      assert Activity.hold(:background) == :disk
      assert Activity.hold(:search) == :disk
    end

    test "network: background from 90% of today's bytes, search only at 100%" do
      put_budget(network_budget_bytes: 1_000)

      Activity.record_bytes("wikipedia", 900)
      assert Activity.hold(:background) == :network
      assert Activity.hold(:search) == nil

      Activity.record_bytes("wikidata", 100)
      assert Activity.hold(:background) == :network
      assert Activity.hold(:search) == :network
    end

    test "a network budget of 0 holds both kinds" do
      put_budget(network_budget_bytes: 0)

      assert Activity.hold(:background) == :network
      assert Activity.hold(:search) == :network
    end

    test "low free disk holds background work only" do
      put_budget(min_free_disk_bytes: 1_000)

      assert Activity.hold(:background, free_disk_bytes: 999) == :free_disk
      assert Activity.hold(:background, free_disk_bytes: 1_000) == nil
      assert Activity.hold(:search, free_disk_bytes: 999) == nil
    end

    test "an unreadable free disk holds background work back, never a search" do
      put_budget(min_free_disk_bytes: 1_000)

      assert Activity.hold(:background, free_disk_bytes: nil) == :free_disk
      assert Activity.hold(:search, free_disk_bytes: nil) == nil
    end

    test "an unreadable free disk does not hold when the floor is 0" do
      put_budget(min_free_disk_bytes: 0)

      assert Activity.hold(:background, free_disk_bytes: nil) == nil
    end
  end

  describe "stats/1" do
    @today ~D[2026-11-10]

    defp stats, do: Activity.stats(today: @today)

    test "is empty on an empty database, with the budget and no passages" do
      assert %{
               searches: %{total: 0, days: []},
               pages: %{search: 0, background: 0, manual: 0},
               passages: 0,
               network: [],
               hit_share: %{background_pages: 0, hit_pages: 0},
               gain: %{pages: 0, searches: 0, window_searches: 0}
             } = stats = stats()

      assert stats.budget.disk.used > 0
      refute Map.has_key?(stats, :disk_bytes)
    end

    test "budget is the one of budget/1 for the day, and passages counts the chunks" do
      Activity.record_bytes("wikipedia", 70, day: @today)
      Activity.record_bytes("wikipedia", 900, day: Date.add(@today, -1))
      document_fixture()
      document_fixture()

      assert %{budget: budget, passages: passages} = stats()
      assert budget.network.used == 70
      assert budget == Activity.budget(today: @today)
      assert passages == Knowseek.Documents.count_chunks()
      assert passages >= 2
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

    test "gain is zero on an empty database" do
      assert %{gain: %{pages: 0, searches: 0, window_searches: 0}} = stats()
    end

    test "gain counts a search with a background page and fewer than 3 other pages" do
      background = document_fixture(origin: "background")
      [a, b, c] = for _ <- 1..3, do: document_fixture(origin: "search")
      now = DateTime.new!(@today, ~T[10:00:00], "Etc/UTC")

      logged_search_fixture(query: "one", documents: [background, a, b], now: now)
      logged_search_fixture(query: "full", documents: [background, a, b, c], now: now)
      logged_search_fixture(query: "no background", documents: [a], now: now)

      assert %{gain: %{pages: 1, searches: 1, window_searches: 3}} = stats()
    end

    test "gain counts a search with only background pages" do
      one = document_fixture(origin: "background")
      two = document_fixture(origin: "background")
      now = DateTime.new!(@today, ~T[10:00:00], "Etc/UTC")

      logged_search_fixture(query: "only", documents: [one, two], now: now)

      assert %{gain: %{pages: 2, searches: 1}} = stats()
    end

    test "gain counts a background page once, and the searches that used it" do
      background = document_fixture(origin: "background")
      other = document_fixture(origin: "search")
      now = DateTime.new!(@today, ~T[10:00:00], "Etc/UTC")

      logged_search_fixture(query: "first", documents: [background, other], now: now)
      logged_search_fixture(query: "second", documents: [background], now: now)

      assert %{gain: %{pages: 1, searches: 2, window_searches: 2}} = stats()
    end

    test "gain pages cover the whole log, searches only the last 30 days" do
      background = document_fixture(origin: "background")
      old = DateTime.new!(~D[2026-10-10], ~T[12:00:00], "Etc/UTC")
      recent = DateTime.new!(@today, ~T[12:00:00], "Etc/UTC")

      logged_search_fixture(query: "old", documents: [background], now: old)
      logged_search_fixture(query: "recent", documents: [], now: recent)

      assert %{gain: %{pages: 1, searches: 0, window_searches: 1}} = stats()
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

  describe "hit_documents/1" do
    test "returns the documents that appeared in a logged search" do
      shown = document_fixture()
      unseen = document_fixture()
      logged_search_fixture(query: "one", documents: [shown])
      logged_search_fixture(query: "two", documents: [shown])

      assert Activity.hit_documents([shown.id, unseen.id, Ecto.UUID.generate()]) ==
               MapSet.new([shown.id])
    end

    test "is empty for no ids" do
      assert Activity.hit_documents([]) == MapSet.new()
    end
  end
end
