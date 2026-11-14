defmodule Knowseek.CrawlTest do
  # Changes the global source list, the crawl config and the embedding adapter.
  use Knowseek.DataCase, async: false

  import ExUnit.CaptureLog

  alias Knowseek.Activity.NetworkUsage
  alias Knowseek.Crawl
  alias Knowseek.Crawl.{Candidate, SourcePage}
  alias Knowseek.Discovery
  alias Knowseek.Discovery.CrawlSource
  alias Knowseek.{Documents, Embeddings}

  # The Hashing adapter makes the cosine of two texts their word overlap:
  # with the query "sourdough starter" (two words), "Desem: sourdough starter"
  # (three words, two shared) scores 2 / sqrt(3 * 2) = 0.816, "Poolish:
  # sourdough starter dough" 2 / sqrt(4 * 2) = 0.707, "Sourdough" and "Levain:
  # sourdough" 0.707 and 0.5, and "Gluten: protein" 0.
  @query "sourdough starter"
  @starter "sourdough starter"
  @desem 0.8165
  @poolish 0.7071
  @day 86_400

  setup do
    discovery = Application.fetch_env!(:knowseek, Discovery)
    crawl = Application.fetch_env!(:knowseek, Crawl)
    activity = Application.fetch_env!(:knowseek, Knowseek.Activity)

    on_exit(fn ->
      Application.put_env(:knowseek, Discovery, discovery)
      Application.put_env(:knowseek, Knowseek.Activity, activity)
      Application.put_env(:knowseek, Crawl, crawl)
      Application.delete_env(:knowseek, CrawlSource)
    end)

    Application.put_env(:knowseek, Discovery, Keyword.put(discovery, :sources, [CrawlSource]))

    configure(
      mode: :preview,
      pages_per_day: 100,
      window_days: 30,
      top_ranks: 3,
      earn_top: 5,
      earn_single: 15,
      earn_rest: 1,
      max_queries: 10,
      interest_floor: 0.4,
      bar: 0.4,
      novelty_full_at: 10,
      gap_bonus: 0.1,
      shared_bonus: 0.1,
      max_candidates: 50,
      reread_days: 7,
      retry_minutes: 60,
      idle_seconds: 600,
      max_cpu_percent: 60
    )

    # A background page is never a source page: it fills a search's results
    # (so that a source page is not its only result) without being read.
    %{filler: document_fixture(origin: "background")}
  end

  describe "mode/0" do
    test "is the configured mode" do
      assert Crawl.mode() == :preview

      configure(mode: :on)
      assert Crawl.mode() == :on

      configure(mode: :off)
      assert Crawl.mode() == :off
    end
  end

  describe "next_action/1" do
    test "is :none when the mode is off", %{filler: filler} do
      configure(mode: :off)
      source_page(filler, 1, @query)

      assert Crawl.next_action() == :none
    end

    test "is :none when no search was logged" do
      assert Crawl.next_action() == :none
    end

    test "is :none for a source page that earned no allowance", %{filler: filler} do
      configure(earn_top: 0)
      source_page(filler, 1, @query)

      assert Crawl.next_action() == :none
    end

    test "is {:read, source} for a source page whose links were not read", %{filler: filler} do
      source = source_page(filler, 1, @query)

      assert {:read, %{document_id: id, queries: [@query], gap: false, earned: 5}} =
               Crawl.next_action()

      assert id == source.id
    end

    test "reads a page that was a search's only result before the others", %{filler: filler} do
      shown_twice = source_page(filler, 1, @query)
      logged_search_fixture(query: "another search", documents: [shown_twice, filler])
      single = crawl_source_fixture(pageid: 2, query: "a lonely search")

      assert {:read, %{document_id: id, gap: true, earned: 15}} = Crawl.next_action()
      assert id == single.id
    end

    test "does not ask for a page again once it was read", %{filler: filler} do
      source_page(filler, 1, @query)

      assert :ok = Crawl.step()

      assert Crawl.next_action() == :none
    end

    test "reads a page again after more than reread_days", %{filler: filler} do
      source = source_page(filler, 1, @query)
      assert :ok = Crawl.step()
      now = DateTime.utc_now(:second)

      assert Crawl.next_action(now: DateTime.add(now, 6 * @day)) == :none

      assert {:read, %{document_id: id}} = Crawl.next_action(now: DateTime.add(now, 8 * @day))
      assert id == source.id
    end

    test "is {:fetch, _} in mode :on once every page was read, with candidates above the bar", %{
      filler: filler
    } do
      configure(mode: :on)
      source_page(filler, 1, @query)
      set_links(%{1 => [link(100, "Desem", @starter)]})

      # Reads come first.
      assert {:read, _source} = Crawl.next_action()

      assert :ok = Crawl.step()
      assert [%Candidate{page_id: 100}] = candidates()

      assert {:fetch, [%{candidate: %Candidate{page_id: 100}, score: score}]} =
               Crawl.next_action()

      assert_in_delta score, @desem, 0.001
    end

    test "is :none in mode :preview once every page was read", %{filler: filler} do
      source_page(filler, 1, @query)
      set_links(%{1 => [link(100, "Desem", @starter)]})

      assert :ok = Crawl.step()
      assert [%Candidate{page_id: 100}] = candidates()

      assert Crawl.next_action() == :none
    end

    test "is :none for a source page whose document is gone", %{filler: filler} do
      source = source_page(filler, 1, @query)
      Repo.delete_all(from d in Documents.Document, where: d.id == ^source.id)

      assert Crawl.next_action() == :none
    end

    test "a background page that tops a later search is not a source page" do
      background =
        document_fixture(
          source: "crawl",
          origin: "background",
          url: "https://en.wikipedia.org/wiki/Page_50",
          metadata: %{"pageid" => 50}
        )

      logged_search_fixture(query: "a later search", documents: [background])

      assert Crawl.next_action() == :none
    end

    test "a background page next to a source page is left out", %{filler: filler} do
      background =
        document_fixture(
          source: "crawl",
          origin: "background",
          url: "https://en.wikipedia.org/wiki/Page_50",
          metadata: %{"pageid" => 50}
        )

      set_links(%{50 => [link(100, "Desem", @starter)], 1 => [link(101, "Poolish", @starter)]})

      real = crawl_source_fixture(pageid: 1, query: @query, alongside: [background, filler])

      assert {:read, %{document_id: id}} = Crawl.next_action()
      assert id == real.id

      assert :ok = Crawl.step()

      assert requests() == 1
      assert [%SourcePage{document_id: ^id}] = Repo.all(SourcePage)
      assert Crawl.next_action() == :none
    end

    test "a source page at zero allowance is not read", %{filler: filler} do
      configure(earn_top: 2)
      source = source_page(filler, 1, @query)
      now = DateTime.utc_now(:second)
      insert_candidate(source.id, 901, state: "fetched", fetched_at: now)
      insert_candidate(source.id, 902, state: "fetched", fetched_at: now)

      assert Crawl.next_action() == :none
    end

    test "a source page with allowance left is read", %{filler: filler} do
      configure(earn_top: 2)
      source = source_page(filler, 1, @query)
      insert_candidate(source.id, 901, state: "fetched", fetched_at: DateTime.utc_now(:second))

      assert {:read, %{document_id: id}} = Crawl.next_action()
      assert id == source.id
    end

    test "pages fetched before the window do not count against the allowance", %{filler: filler} do
      configure(earn_top: 2)
      source = source_page(filler, 1, @query)
      long_ago = DateTime.add(DateTime.utc_now(:second), -31 * @day)
      insert_candidate(source.id, 901, state: "fetched", fetched_at: long_ago)
      insert_candidate(source.id, 902, state: "fetched", fetched_at: long_ago)

      assert {:read, %{document_id: id}} = Crawl.next_action()
      assert id == source.id
    end
  end

  describe "due?/1" do
    test "is false when the mode is off", %{filler: filler} do
      configure(mode: :off)
      source_page(filler, 1, @query)

      refute Crawl.due?(idle_opts())
      refute Crawl.due?()
    end

    test "is false when the instance is not idle", %{filler: filler} do
      source_page(filler, 1, @query)
      now = DateTime.utc_now()

      refute Crawl.due?(now: now, last_search_at: DateTime.add(now, -10), cpu: 0.0)
      refute Crawl.due?(now: now, last_search_at: DateTime.add(now, -3_600), cpu: 90.0)
    end

    test "is false when there is nothing to do", %{filler: filler} do
      refute Crawl.due?(idle_opts())

      source_page(filler, 1, @query)
      assert :ok = Crawl.step()

      refute Crawl.due?(idle_opts())
    end

    test "is true when the mode is on, the instance idle and a page can be read", %{
      filler: filler
    } do
      source_page(filler, 1, @query)

      assert Crawl.due?(idle_opts())

      configure(mode: :on)
      assert Crawl.due?(idle_opts())
    end

    test "only reads: it does not read a page", %{filler: filler} do
      source_page(filler, 1, @query)

      assert Crawl.due?(idle_opts())

      assert requests() == 0
      assert Repo.all(SourcePage) == []
    end
  end

  describe "step/1 reading" do
    test "reads one source page through its source and stores the candidates", %{
      filler: filler
    } do
      source = source_page(filler, 1, @query)

      set_links(%{
        1 => [
          link(100, "Desem", @starter),
          link(101, "Sourdough"),
          link(102, "Gluten", "protein")
        ]
      })

      assert :ok = Crawl.step()

      assert requests() == 1
      id = source.id

      assert %SourcePage{site: "crawl", link_ids: [100, 101, 102], links: 3, kept: 2} =
               Repo.get(SourcePage, id)

      assert [desem, sourdough] = candidates()

      assert %Candidate{
               source_document_id: ^id,
               page_id: 100,
               site: "crawl",
               title: "Desem",
               description: "sourdough starter",
               url: "https://en.wikipedia.org/?curid=100",
               shared_count: 1,
               state: "pending",
               document_id: nil,
               fetched_at: nil
             } = desem

      assert_in_delta desem.interest, @desem, 0.001
      assert_in_delta desem.novelty, 1.0, 0.001
      assert_in_delta desem.gap, 0.0, 0.001
      assert_in_delta desem.shared, 0.0, 0.001
      assert_in_delta desem.score, @desem, 0.001

      assert %Candidate{page_id: 101, title: "Sourdough", description: nil} = sourdough
      assert_in_delta sourdough.interest, @poolish, 0.001

      # Read once: the next step has nothing to do.
      assert :ok = Crawl.step()
      assert requests() == 1
    end

    test "does nothing when the mode is off", %{filler: filler} do
      configure(mode: :off)
      source_page(filler, 1, @query)
      set_links(%{1 => [link(100, "Desem", @starter)]})

      assert :ok = Crawl.step()

      assert requests() == 0
      assert Repo.all(SourcePage) == []
      assert candidates() == []
    end

    test "does nothing when no page was shown by a search" do
      assert :ok = Crawl.step()

      assert requests() == 0
      assert Repo.all(SourcePage) == []
    end

    test "leaves out the pages that are indexed", %{filler: filler} do
      source = source_page(filler, 1, @query)

      document_fixture(
        source: "crawl",
        url: "https://en.wikipedia.org/wiki/Desem",
        title: "Desem",
        body: "Notes about weather and rain.",
        metadata: %{"pageid" => 100}
      )

      set_links(%{1 => [link(100, "Desem", @starter), link(101, "Poolish", @starter)]})

      assert :ok = Crawl.step()

      assert [%Candidate{page_id: 101}] = candidates()
      # The indexed page still counts among the page's links.
      assert %SourcePage{link_ids: [100, 101], links: 2, kept: 1} =
               Repo.get(SourcePage, source.id)
    end

    test "leaves out the pages that were skipped", %{filler: filler} do
      source_page(filler, 1, @query)
      insert_candidate(filler.id, 100, state: "skipped")
      set_links(%{1 => [link(100, "Desem", @starter), link(101, "Poolish", @starter)]})

      assert :ok = Crawl.step()

      assert [%Candidate{page_id: 100, state: "skipped"}, %Candidate{page_id: 101}] = candidates()
    end

    test "does not store a candidate under the interest floor", %{filler: filler} do
      configure(interest_floor: 0.6, bar: 0.0)
      source = source_page(filler, 1, @query)

      set_links(%{
        1 => [
          link(100, "Desem", @starter),
          link(101, "Levain", "sourdough"),
          link(102, "Gluten", "protein")
        ]
      })

      assert :ok = Crawl.step()

      assert [%Candidate{page_id: 100}] = candidates()
      assert %SourcePage{links: 3, kept: 1} = Repo.get(SourcePage, source.id)
    end

    test "does not store a candidate that could not reach the bar even with a shared bonus", %{
      filler: filler
    } do
      # 0.816 + the largest shared bonus 0.1 = 0.916.
      configure(bar: 0.95)
      source = source_page(filler, 1, @query)
      set_links(%{1 => [link(100, "Desem", @starter)]})

      assert :ok = Crawl.step()

      assert candidates() == []
      assert %SourcePage{links: 1, kept: 0} = Repo.get(SourcePage, source.id)
    end

    test "stores a candidate that could reach the bar with a shared bonus", %{filler: filler} do
      configure(bar: 0.9)
      source_page(filler, 1, @query)
      set_links(%{1 => [link(100, "Desem", @starter)]})

      assert :ok = Crawl.step()

      assert [%Candidate{page_id: 100}] = candidates()
    end

    test "novelty falls with the stored pages near a candidate", %{filler: filler} do
      configure(novelty_full_at: 2)
      store_near(1)
      source_page(filler, 1, @query)
      set_links(%{1 => [link(100, "Desem", @starter)]})

      assert :ok = Crawl.step()

      assert [desem] = candidates()
      assert_in_delta desem.interest, @desem, 0.001
      assert_in_delta desem.novelty, 0.5, 0.001
      assert_in_delta desem.score, @desem * 0.5, 0.001
    end

    test "a candidate with as many stored pages near it as novelty_full_at is not stored", %{
      filler: filler
    } do
      configure(novelty_full_at: 2)
      store_near(2)
      source_page(filler, 1, @query)
      set_links(%{1 => [link(100, "Desem", @starter)]})

      assert :ok = Crawl.step()

      # Novelty 0: the score is 0, and 0 + 0.1 is under the bar.
      assert candidates() == []
    end

    test "adds the gap bonus only for a page that was a search's only result", %{
      filler: filler
    } do
      single = crawl_source_fixture(pageid: 1, query: @query)
      shared = source_page(filler, 2, "starter sourdough")

      set_links(%{
        1 => [link(100, "Desem", @starter)],
        2 => [link(200, "Poolish", @starter)]
      })

      assert :ok = Crawl.step()
      assert :ok = Crawl.step()

      assert [from_single, from_shared] = candidates()

      assert %Candidate{page_id: 100, source_document_id: single_id} = from_single
      assert single_id == single.id
      assert_in_delta from_single.gap, 0.1, 0.001
      assert_in_delta from_single.score, @desem + 0.1, 0.001

      assert %Candidate{page_id: 200, source_document_id: shared_id} = from_shared
      assert shared_id == shared.id
      assert_in_delta from_shared.gap, 0.0, 0.001
      assert_in_delta from_shared.score, @desem, 0.001
    end

    test "stores at most max_candidates, the best first", %{filler: filler} do
      configure(max_candidates: 2, interest_floor: 0.0, bar: 0.0)
      source = source_page(filler, 1, @query)

      set_links(%{
        1 => [
          link(101, "Levain", "sourdough"),
          link(102, "Poolish", "sourdough starter dough"),
          link(103, "Desem", @starter)
        ]
      })

      assert :ok = Crawl.step()

      assert Enum.map(candidates(), & &1.page_id) == [102, 103]

      assert %SourcePage{links: 3, kept: 2, link_ids: [101, 102, 103]} =
               Repo.get(SourcePage, source.id)
    end

    test "a second read replaces the pending rows and keeps the fetched ones", %{filler: filler} do
      source = source_page(filler, 1, @query)

      set_links(%{
        1 => [link(100, "Alpha", @starter), link(999, "Beta", @starter)]
      })

      assert :ok = Crawl.step()

      assert Enum.map(candidates(), &{&1.page_id, &1.state}) == [
               {100, "pending"},
               {999, "pending"}
             ]

      # The crawl fetched page 999 meanwhile.
      now = DateTime.utc_now(:second)

      Repo.update_all(from(c in Candidate, where: c.page_id == 999),
        set: [state: "fetched", fetched_at: now]
      )

      set_links(%{
        1 => [link(999, "Beta", @starter), link(101, "Gamma", @starter)]
      })

      later = DateTime.add(now, 8 * @day)
      assert :ok = Crawl.step(now: later)

      assert requests() == 2

      assert Enum.map(candidates(), &{&1.page_id, &1.state}) == [
               {101, "pending"},
               {999, "fetched"}
             ]

      assert %SourcePage{link_ids: [999, 101], links: 2, kept: 1, read_at: read_at} =
               Repo.get(SourcePage, source.id)

      assert read_at == later
    end

    test "a failed embedding stores nothing and sends no request", %{filler: filler} do
      source_page(filler, 1, @query)
      set_links(%{1 => [link(100, "Desem", @starter)]})

      config = Application.fetch_env!(:knowseek, Embeddings)
      on_exit(fn -> Application.put_env(:knowseek, Embeddings, config) end)

      Application.put_env(
        :knowseek,
        Embeddings,
        Keyword.put(config, :adapter, Knowseek.Embeddings.ShortAdapter)
      )

      log = capture_log(fn -> assert :ok = Crawl.step() end)

      assert log =~ "crawl: reading links of"
      assert requests() == 0
      assert Repo.all(SourcePage) == []
      assert candidates() == []

      # Nothing was recorded as read: the next step tries again.
      assert {:read, _source} = Crawl.next_action()
    end

    test "a failed request stores nothing, and the next step tries again", %{filler: filler} do
      defmodule ErrorSource do
        @behaviour Knowseek.Discovery.Source
        def name, do: "crawl"
        def discover(_query, _opts), do: {:ok, []}
        def link_candidates(_document, _opts), do: {:error, :unavailable}
        def page(_page_id, _opts), do: {:error, :unavailable}
      end

      source_page(filler, 1, @query)
      set_links(%{1 => [link(100, "Desem", @starter)]})
      config = Application.fetch_env!(:knowseek, Discovery)
      Application.put_env(:knowseek, Discovery, Keyword.put(config, :sources, [ErrorSource]))

      log = capture_log(fn -> assert :ok = Crawl.step() end)

      assert log =~ "unavailable"
      assert Repo.all(SourcePage) == []
      assert candidates() == []
      assert {:read, _source} = Crawl.next_action()

      Application.put_env(:knowseek, Discovery, config)

      assert :ok = Crawl.step()
      assert [%Candidate{page_id: 100}] = candidates()
    end

    test "a source page whose source has no link_candidates/2 gets a row with no links" do
      document = document_fixture(source: "test")
      logged_search_fixture(query: @query, documents: [document])

      assert :ok = Crawl.step()

      assert requests() == 0

      assert %SourcePage{site: "test", link_ids: [], links: 0, kept: 0} =
               Repo.get(SourcePage, document.id)

      assert candidates() == []

      # Not tried again until it is old.
      assert Crawl.next_action() == :none
    end

    test "does not read a source page at zero allowance", %{filler: filler} do
      configure(earn_top: 2)
      source = source_page(filler, 1, @query)
      set_links(%{1 => [link(100, "Desem", @starter)]})
      now = DateTime.utc_now(:second)
      insert_candidate(source.id, 901, state: "fetched", fetched_at: now)
      insert_candidate(source.id, 902, state: "fetched", fetched_at: now)

      assert :ok = Crawl.step()

      assert requests() == 0
      assert Repo.all(SourcePage) == []
    end

    test "in mode :preview it reads and scores, and fetches nothing", %{filler: filler} do
      source_page(filler, 1, @query)
      set_links(%{1 => [link(100, "Desem", @starter)]})
      documents = Repo.aggregate(Documents.Document, :count)
      # The `filler` is the one background page.
      assert Documents.count_by_origin().background == 1

      assert :ok = Crawl.step()
      assert :ok = Crawl.step()

      assert requests() == 1
      assert [%Candidate{page_id: 100, state: "pending", document_id: nil}] = candidates()
      assert Repo.aggregate(Documents.Document, :count) == documents
      assert Documents.count_by_origin().background == 1
      assert Crawl.next_action() == :none
      assert %{mode: :preview, fetched: 0, fetched_today: 0} = Crawl.stats()
    end
  end

  describe "step/1 fetching" do
    setup %{filler: filler} do
      configure(mode: :on, rechecks_per_step: 5)
      source = source_page(filler, 1, @query, title: "Sourdough")

      set_links(%{
        1 => [link(100, "Desem", @starter), link(101, "Poolish", "sourdough starter dough")]
      })

      set_pages(%{
        100 => %{
          title: "Desem",
          body: "Desem is a sourdough starter made from whole wheat flour."
        },
        101 => %{
          title: "Poolish",
          body: "A poolish is a pre-ferment of equal parts flour and water."
        }
      })

      # The first step reads the links (a 900-byte request).
      assert :ok = Crawl.step()
      assert crawl_bytes() == 900

      %{source: source}
    end

    test "fetches the best candidate as a background page, and records it", %{source: source} do
      assert {:fetch, [%{candidate: %{page_id: 100}}, %{candidate: %{page_id: 101}}]} =
               Crawl.next_action()

      assert :ok = Crawl.step()

      assert %Documents.Document{
               id: id,
               origin: "background",
               origin_query: nil,
               source: "crawl",
               title: "Desem"
             } = Repo.get_by!(Documents.Document, url: "https://en.wikipedia.org/wiki/Page_100")

      source_id = source.id

      assert [
               %Candidate{
                 page_id: 100,
                 state: "fetched",
                 source_document_id: ^source_id,
                 document_id: ^id,
                 stored_bytes: stored_bytes,
                 fetched_at: %DateTime{}
               } = fetched,
               %Candidate{page_id: 101, state: "pending", document_id: nil}
             ] = candidates()

      assert stored_bytes == Documents.stored_bytes(id)
      assert stored_bytes > 0
      assert_in_delta fetched.novelty, 1.0, 0.001
      assert_in_delta fetched.score, @desem, 0.001
      # The page request was counted for the source: 900 + 800 bytes.
      assert crawl_bytes() == 1_700
    end

    test "a held budget sends no request and stores nothing", %{source: source} do
      before_action = Crawl.next_action()
      assert {:fetch, [_, _]} = before_action
      source_id = source.id

      limit_budget(disk_budget_bytes: 0)

      assert :ok = Crawl.step()

      assert crawl_bytes() == 900
      assert Repo.get_by(Documents.Document, url: "https://en.wikipedia.org/wiki/Page_100") == nil
      assert [%Candidate{state: "pending"}, %Candidate{state: "pending"}] = candidates()
      assert [%SourcePage{document_id: ^source_id}] = Repo.all(SourcePage)
      assert Crawl.next_action() == before_action
      refute Crawl.due?(idle_opts())

      limit_budget(disk_budget_bytes: 5_000_000_000)
      assert :ok = Crawl.step()
      assert crawl_bytes() == 1_700
    end

    test "fetches one page a step, the best first, and then has nothing left" do
      assert :ok = Crawl.step()
      assert :ok = Crawl.step()

      assert Enum.map(candidates(), &{&1.page_id, &1.state}) == [
               {100, "fetched"},
               {101, "fetched"}
             ]

      assert Documents.count_by_origin().background == 3
      assert Crawl.next_action() == :none

      assert :ok = Crawl.step()
      assert crawl_bytes() == 900 + 2 * 800
    end

    test "reads every source page before it fetches", %{filler: filler} do
      source_page(filler, 2, "starter sourdough", title: "Starter")
      set_links(%{1 => [], 2 => [link(102, "Levain", "sourdough starter")]})

      assert {:read, _source} = Crawl.next_action()
      assert :ok = Crawl.step()

      assert crawl_bytes() == 1_800
      assert Documents.count_by_origin().background == 1
      assert {:fetch, _ranked} = Crawl.next_action()
    end

    test "deletes the other pending rows of a page that two source pages link to", %{
      filler: filler
    } do
      source_page(filler, 2, "starter sourdough", title: "Starter")
      set_links(%{2 => [link(100, "Desem", @starter)]})
      assert :ok = Crawl.step()
      assert Enum.count(candidates(), &(&1.page_id == 100)) == 2

      assert :ok = Crawl.step()

      assert [%Candidate{state: "fetched"}] = Enum.filter(candidates(), &(&1.page_id == 100))
    end

    test "logs the links of the page that go off the allowlist" do
      set_pages(%{
        100 => %{
          title: "Desem",
          body: "Desem is a sourdough starter made from whole wheat flour.",
          links: ["https://example.com/a", "https://en.wikipedia.org/wiki/Flour"]
        }
      })

      assert :ok = Crawl.step()

      assert %{domains: [%{host: "example.com", links: 1, pages: 1}]} =
               Discovery.blocked_domains()
    end

    test "fetches nothing in mode :preview" do
      configure(mode: :preview)

      assert Crawl.next_action() == :none
      refute Crawl.due?(idle_opts())

      assert :ok = Crawl.step()

      assert crawl_bytes() == 900
      assert Documents.count_by_origin().background == 1
      assert [%Candidate{state: "pending"}, %Candidate{state: "pending"}] = candidates()
    end

    test "is due in mode :on when a candidate is left" do
      assert Crawl.due?(idle_opts())
    end

    test "stops at pages_per_day, and starts again the next UTC day" do
      configure(pages_per_day: 1)
      assert :ok = Crawl.step()

      assert Crawl.next_action() == :none
      refute Crawl.due?(idle_opts())
      assert :ok = Crawl.step()
      assert crawl_bytes() == 1_700

      tomorrow = DateTime.add(DateTime.utc_now(), 1 * @day)
      assert {:fetch, [%{candidate: %{page_id: 101}}]} = Crawl.next_action(now: tomorrow)
    end

    test "a fetched page uses up the source page's allowance" do
      configure(earn_top: 1)
      assert :ok = Crawl.step()

      assert Crawl.next_action() == :none
      assert [%{page_id: 100, state: "fetched"}, %{page_id: 101, state: "pending"}] = candidates()
    end

    test "scores the candidate again right before the fetch" do
      store_near(3)

      assert :ok = Crawl.step()

      assert [%Candidate{page_id: 100, state: "fetched"} = fetched | _rest] = candidates()
      assert_in_delta fetched.novelty, 0.7, 0.001
      assert_in_delta fetched.score, @desem * 0.7, 0.001
    end

    test "drops a candidate whose novelty fell under the bar, and fetches the next one" do
      store_near(10)

      assert :ok = Crawl.step()

      assert Enum.map(candidates(), &{&1.page_id, &1.state}) == [{101, "fetched"}]
      # Only the page of the second candidate was requested.
      assert crawl_bytes() == 900 + 800
      refute Repo.get_by(Documents.Document, url: "https://en.wikipedia.org/wiki/Page_100")
    end

    test "tries at most rechecks_per_step candidates in a step" do
      configure(rechecks_per_step: 1)
      store_near(10)

      assert :ok = Crawl.step()

      assert Enum.map(candidates(), &{&1.page_id, &1.state}) == [{101, "pending"}]
      assert crawl_bytes() == 900

      assert :ok = Crawl.step()

      assert Enum.map(candidates(), &{&1.page_id, &1.state}) == [{101, "fetched"}]
    end

    test "deletes a candidate whose page was indexed meanwhile, without a request" do
      document_fixture(
        source: "crawl",
        url: "https://en.wikipedia.org/wiki/Page_100",
        title: "Desem",
        body: "Stored by a search.",
        metadata: %{"pageid" => 100}
      )

      assert :ok = Crawl.step()

      assert Enum.map(candidates(), &{&1.page_id, &1.state}) == [{101, "fetched"}]
      assert crawl_bytes() == 900 + 800
    end

    test "keeps the origin of a page that a search stored under its own URL meanwhile" do
      existing =
        document_fixture(
          source: "crawl",
          origin: "search",
          origin_query: "desem",
          url: "https://en.wikipedia.org/wiki/Page_100",
          title: "Desem",
          body: "Stored by a search."
        )

      assert :ok = Crawl.step()

      assert %Documents.Document{origin: "search", origin_query: "desem"} =
               Documents.get_document(existing.id)

      assert Enum.map(candidates(), &{&1.page_id, &1.state}) == [{101, "pending"}]
    end

    test "skips a page that has no text, and never offers it again" do
      set_pages(%{101 => %{title: "Poolish", body: "A poolish is a pre-ferment."}})

      assert :ok = Crawl.step()

      assert Enum.map(candidates(), &{&1.page_id, &1.state}) == [
               {100, "skipped"},
               {101, "pending"}
             ]

      assert Documents.count_by_origin().background == 1
      assert crawl_bytes() == 900 + 800
      assert {:fetch, [%{candidate: %{page_id: 101}}]} = Crawl.next_action()
    end

    test "skips a candidate whose URL is off the allowlist, without a request" do
      Repo.update_all(from(c in Candidate, where: c.page_id == 100),
        set: [url: "https://example.com/?curid=100"]
      )

      assert :ok = Crawl.step()

      assert Enum.map(candidates(), &{&1.page_id, &1.state}) == [
               {100, "skipped"},
               {101, "pending"}
             ]

      assert crawl_bytes() == 900
    end

    test "a failed request leaves the candidate alone for retry_minutes" do
      set_pages(%{
        100 => {:error, :boom},
        101 => %{title: "Poolish", body: "A poolish is a pre-ferment of equal parts flour."}
      })

      log = capture_log(fn -> assert :ok = Crawl.step() end)

      assert log =~ "crawl: fetching Desem failed: :boom"

      assert [%Candidate{page_id: 100, state: "pending", failed_at: %DateTime{}}, _] =
               candidates()

      # Desem waits; the next step takes Poolish.
      assert {:fetch, [%{candidate: %{page_id: 101}}]} = Crawl.next_action()
      assert :ok = Crawl.step()
      assert Crawl.next_action() == :none

      later = DateTime.add(DateTime.utc_now(), 61 * 60)
      assert {:fetch, [%{candidate: %{page_id: 100}}]} = Crawl.next_action(now: later)
    end

    test "a failed embedding stops the step before any request" do
      config = Application.fetch_env!(:knowseek, Embeddings)
      on_exit(fn -> Application.put_env(:knowseek, Embeddings, config) end)

      Application.put_env(
        :knowseek,
        Embeddings,
        Keyword.put(config, :adapter, Knowseek.Embeddings.ShortAdapter)
      )

      log = capture_log(fn -> assert :ok = Crawl.step() end)

      assert log =~ "crawl: embedding Desem failed"
      assert crawl_bytes() == 900
      assert [%Candidate{state: "pending"}, %Candidate{state: "pending"}] = candidates()
    end

    test "overview/1 lists the fetched pages with their source page and whether a search showed them" do
      assert :ok = Crawl.step()
      url = "https://en.wikipedia.org/wiki/Page_100"
      %Documents.Document{id: id} = Repo.get_by!(Documents.Document, url: url)

      assert %{
               fetched_today: 1,
               next: [%{title: "Poolish", document_id: nil, fetched_at: nil, hit: false}],
               fetched: [fetched]
             } = Crawl.overview()

      assert %{
               title: "Desem",
               description: "sourdough starter",
               url: ^url,
               source: %{title: "Sourdough", queries: [@query]},
               document_id: ^id,
               stored_bytes: stored_bytes,
               hit: false,
               shared_count: 1
             } = fetched

      assert stored_bytes == Documents.stored_bytes(id)
      assert %DateTime{} = fetched.fetched_at
      assert_in_delta fetched.score, @desem, 0.001

      logged_search_fixture(query: "desem", documents: [Documents.get_document(id)])

      assert %{fetched: [%{hit: true}]} = Crawl.overview()
    end

    test "overview/1 lists the fetched pages newest first, cut by :limit", %{source: source} do
      now = DateTime.utc_now(:second)
      insert_candidate(source.id, 901, state: "fetched", fetched_at: DateTime.add(now, -60))
      insert_candidate(source.id, 902, state: "fetched", fetched_at: now)
      insert_candidate(source.id, 903, state: "fetched", fetched_at: DateTime.add(now, -120))

      assert %{fetched: fetched} = Crawl.overview()
      assert Enum.map(fetched, & &1.title) == ["Title 902", "Title 901", "Title 903"]

      assert %{fetched: [%{title: "Title 902"}]} = Crawl.overview(limit: 1)
    end

    test "stats/1 counts the fetched pages and their stored bytes" do
      assert :ok = Crawl.step()
      url = "https://en.wikipedia.org/wiki/Page_100"
      %Documents.Document{id: id} = Repo.get_by!(Documents.Document, url: url)

      assert %{fetched: 1, fetched_today: 1, stored_bytes: bytes} = Crawl.stats()
      assert bytes == Documents.stored_bytes(id)
    end
  end

  describe "overview/1" do
    test "is empty when nothing was read" do
      assert %{mode: :preview, pages_per_day: 100, fetched_today: 0, bar: 0.4, next: []} =
               Crawl.overview()
    end

    test "lists the candidates in the order they would be fetched, with their source page", %{
      filler: filler
    } do
      source = source_page(filler, 7, @query, title: "Sourdough")

      set_links(%{
        7 => [
          link(101, "Levain", "sourdough"),
          link(102, "Poolish", "sourdough starter dough"),
          link(103, "Desem", @starter)
        ]
      })

      assert :ok = Crawl.step()

      assert %{mode: :preview, bar: 0.4, next: [desem, poolish, levain]} = Crawl.overview()
      assert Enum.map([desem, poolish, levain], & &1.title) == ["Desem", "Poolish", "Levain"]

      assert %{
               title: "Desem",
               description: "sourdough starter",
               url: "https://en.wikipedia.org/?curid=103",
               source: %{
                 document_id: source_id,
                 title: "Sourdough",
                 url: "https://en.wikipedia.org/wiki/Page_7",
                 queries: [@query]
               },
               shared_count: 1
             } = desem

      assert source_id == source.id
      assert_in_delta desem.interest, @desem, 0.001
      assert_in_delta desem.novelty, 1.0, 0.001
      assert_in_delta desem.gap, 0.0, 0.001
      assert_in_delta desem.shared, 0.0, 0.001
      assert_in_delta desem.score, @desem, 0.001
      assert_in_delta poolish.score, @poolish, 0.001
      assert_in_delta levain.score, 0.5, 0.001

      assert desem |> Map.keys() |> Enum.sort() ==
               ~w(description document_id fetched_at gap hit interest novelty score shared shared_count source stored_bytes title url)a
    end

    test ":limit cuts the list", %{filler: filler} do
      source_page(filler, 1, @query)

      set_links(%{
        1 => [link(100, "Desem", @starter), link(101, "Poolish", "sourdough starter dough")]
      })

      assert :ok = Crawl.step()

      assert %{next: [%{title: "Desem"}]} = Crawl.overview(limit: 1)
      assert %{next: [_, _]} = Crawl.overview()
    end

    test "does not list a candidate under the bar that has no shared bonus", %{filler: filler} do
      # Stored: 0.816 + 0.1 reaches 0.9. Listed: 0.816 does not.
      configure(bar: 0.9)
      source_page(filler, 1, @query)
      set_links(%{1 => [link(100, "Desem", @starter)]})

      assert :ok = Crawl.step()

      assert [%Candidate{page_id: 100}] = candidates()
      assert %{next: []} = Crawl.overview()
    end

    test "a candidate linked from 2 of 3 read pages gets a shared bonus, and is listed once", %{
      filler: filler
    } do
      one = source_page(filler, 1, @query)
      two = source_page(filler, 2, "starter sourdough")
      source_page(filler, 3, "Sourdough Starter")

      set_links(%{
        1 => [
          link(100, "Alpha", @starter),
          link(101, "Beta", @starter),
          link(102, "Gamma", @starter),
          link(103, "Delta", @starter)
        ],
        2 => [
          link(100, "Alpha", @starter),
          link(104, "Epsilon", @starter),
          link(105, "Zeta", @starter),
          link(106, "Eta", @starter)
        ],
        3 => [
          link(107, "Theta", @starter),
          link(108, "Iota", @starter),
          link(109, "Kappa", @starter),
          link(110, "Lambda", @starter)
        ]
      })

      for _ <- 1..3, do: assert(:ok = Crawl.step())

      assert %{next: [alpha | rest]} = Crawl.overview()

      assert %{title: "Alpha", shared_count: 2, source: %{document_id: source_id}} = alpha
      assert source_id in [one.id, two.id]
      # 4 links, 1 of them linked from 2 pages: rarity ln(4 / 1) / ln(4) = 1,
      # shared = 0.1 * 1 / 2 * 1.
      assert_in_delta alpha.shared, 0.05, 0.001
      assert_in_delta alpha.score, @desem + 0.05, 0.001

      assert length(rest) == 10
      assert Enum.all?(rest, &(&1.shared_count == 1))
      assert Enum.all?(rest, &(abs(&1.shared) < 0.001))
      assert Enum.count([alpha | rest], &(&1.title == "Alpha")) == 1
    end

    test "gets no shared bonus when all the page's links are shared", %{filler: filler} do
      source_page(filler, 1, @query)
      source_page(filler, 2, "starter sourdough")
      source_page(filler, 3, "Sourdough Starter")

      set_links(%{
        1 => [link(100, "Alpha", @starter), link(101, "Beta", @starter)],
        2 => [link(100, "Alpha", @starter), link(101, "Beta", @starter)],
        3 => [link(102, "Gamma", @starter)]
      })

      for _ <- 1..3, do: assert(:ok = Crawl.step())

      assert %{next: entries} = Crawl.overview()
      assert entries |> Enum.map(& &1.title) |> Enum.sort() == ["Alpha", "Beta", "Gamma"]

      for entry <- entries do
        assert_in_delta entry.shared, 0.0, 0.001
        assert_in_delta entry.score, @desem, 0.001
      end

      assert %{shared_count: 2} = Enum.find(entries, &(&1.title == "Alpha"))
      assert %{shared_count: 1} = Enum.find(entries, &(&1.title == "Gamma"))
    end

    test "the shared bonus can lift a candidate over the bar", %{filler: filler} do
      configure(bar: 0.85)
      source_page(filler, 1, @query)
      source_page(filler, 2, "starter sourdough")

      set_links(%{
        1 => [link(100, "Alpha", @starter), link(101, "Beta", @starter)],
        2 => [link(100, "Alpha", @starter), link(102, "Gamma", @starter)]
      })

      for _ <- 1..2, do: assert(:ok = Crawl.step())

      assert length(candidates()) == 4
      assert %{next: [%{title: "Alpha", shared_count: 2}]} = Crawl.overview()
    end

    test "does not rank the candidates of a source page at zero allowance", %{filler: filler} do
      configure(earn_top: 2)
      source = source_page(filler, 1, @query)
      set_links(%{1 => [link(100, "Desem", @starter)]})
      assert :ok = Crawl.step()
      assert %{next: [%{title: "Desem"}]} = Crawl.overview()

      now = DateTime.utc_now(:second)
      insert_candidate(source.id, 901, state: "fetched", fetched_at: now)
      assert %{next: [%{title: "Desem"}]} = Crawl.overview()

      insert_candidate(source.id, 902, state: "fetched", fetched_at: now)
      assert %{next: []} = Crawl.overview()

      # The rows are still there.
      assert Enum.map(candidates(), & &1.page_id) == [100, 901, 902]
    end

    test "does not rank the candidates of a source page whose document is gone", %{filler: filler} do
      source = source_page(filler, 1, @query)
      set_links(%{1 => [link(100, "Desem", @starter)]})
      assert :ok = Crawl.step()

      Repo.delete_all(from d in Documents.Document, where: d.id == ^source.id)

      assert %{next: []} = Crawl.overview()
    end

    test "counts today's fetched pages", %{filler: filler} do
      configure(pages_per_day: 7)
      source = source_page(filler, 1, @query)
      now = DateTime.utc_now(:second)
      insert_candidate(source.id, 901, state: "fetched", fetched_at: now)
      insert_candidate(source.id, 902, state: "fetched", fetched_at: DateTime.add(now, -2 * @day))

      assert %{pages_per_day: 7, fetched_today: 1} = Crawl.overview(now: now)
    end
  end

  describe "stats/1" do
    test "is zero when nothing was read" do
      assert %{
               mode: :preview,
               pages_per_day: 100,
               fetched_today: 0,
               fetched: 0,
               links_read: 0,
               candidates: 0,
               stored_bytes: 0
             } = Crawl.stats()
    end

    test "counts the links read, the pending candidates and the fetched pages", %{
      filler: filler
    } do
      configure(pages_per_day: 7)
      source = source_page(filler, 1, @query)
      set_links(%{1 => [link(100, "Desem", @starter), link(101, "Gluten", "protein")]})
      assert :ok = Crawl.step()

      assert %{
               mode: :preview,
               pages_per_day: 7,
               fetched_today: 0,
               fetched: 0,
               links_read: 2,
               candidates: 1,
               stored_bytes: 0
             } = Crawl.stats()

      now = DateTime.utc_now(:second)

      insert_candidate(source.id, 901,
        state: "fetched",
        fetched_at: now,
        stored_bytes: 1_234
      )

      insert_candidate(source.id, 902,
        state: "fetched",
        fetched_at: DateTime.add(now, -2 * @day),
        stored_bytes: 100
      )

      assert %{
               fetched_today: 1,
               fetched: 2,
               links_read: 2,
               candidates: 1,
               stored_bytes: 1_334
             } = Crawl.stats(now: now)
    end
  end

  describe "a held budget" do
    test "makes due?/1 false although the instance is idle and a page is unread", %{
      filler: filler
    } do
      source_page(filler, 1, @query)
      assert Crawl.due?(idle_opts())

      limit_budget(disk_budget_bytes: 0)
      refute Crawl.due?(idle_opts())

      limit_budget(disk_budget_bytes: 5_000_000_000, network_budget_bytes: 0)
      refute Crawl.due?(idle_opts())

      limit_budget(network_budget_bytes: 200_000_000)
      assert Crawl.due?(idle_opts())
    end

    test "makes step/1 send no request and store nothing for a read", %{filler: filler} do
      source_page(filler, 1, @query)
      set_links(%{1 => [link(100, "Desem", @starter)]})
      before_action = Crawl.next_action()
      assert {:read, _source} = before_action

      limit_budget(network_budget_bytes: 0)

      assert :ok = Crawl.step()

      assert requests() == 0
      assert Repo.all(SourcePage) == []
      assert candidates() == []
      assert Crawl.next_action() == before_action

      limit_budget(network_budget_bytes: 200_000_000)
      assert :ok = Crawl.step()
      assert requests() == 1
      assert [%Candidate{page_id: 100}] = candidates()
    end

    test "stops the crawl at the background share, before the limit", %{filler: filler} do
      source_page(filler, 1, @query)
      # Today's usage is 900 bytes: 90% of 1,000 is 900, so background work is held.
      Knowseek.Activity.record_bytes("elsewhere", 900)
      limit_budget(network_budget_bytes: 1_000)

      refute Crawl.due?(idle_opts())
      assert Knowseek.Activity.hold(:search) == nil
      assert %{paused: :network} = Crawl.overview()
    end

    test "shows in overview/1 as paused, and nil when nothing holds" do
      assert %{paused: nil} = Crawl.overview()

      limit_budget(disk_budget_bytes: 0)
      assert %{paused: :disk} = Crawl.overview()

      limit_budget(disk_budget_bytes: 5_000_000_000, network_budget_bytes: 0)
      assert %{paused: :network} = Crawl.overview()

      limit_budget(network_budget_bytes: 200_000_000)
      assert %{paused: nil} = Crawl.overview()
    end
  end

  describe "clear_pending/0" do
    test "deletes the link lists and the pending candidates, and keeps the fetched rows", %{
      filler: filler
    } do
      source = source_page(filler, 1, @query)

      set_links(%{
        1 => [link(100, "Desem", @starter), link(101, "Poolish", "sourdough starter dough")]
      })

      assert :ok = Crawl.step()
      insert_candidate(source.id, 901, state: "fetched", fetched_at: DateTime.utc_now(:second))
      insert_candidate(source.id, 902, state: "skipped")

      assert {:ok, 2} = Crawl.clear_pending()

      assert Repo.all(SourcePage) == []

      assert Enum.map(candidates(), &{&1.page_id, &1.state}) == [
               {901, "fetched"},
               {902, "skipped"}
             ]

      # The page can be read again.
      assert {:read, %{document_id: id}} = Crawl.next_action()
      assert id == source.id
    end

    test "is {:ok, 0} when there is nothing" do
      assert {:ok, 0} = Crawl.clear_pending()
    end
  end

  # Overrides the budget limits (the test config makes no free-disk reading).
  defp limit_budget(overrides) do
    Application.put_env(
      :knowseek,
      Knowseek.Activity,
      Keyword.merge(Application.fetch_env!(:knowseek, Knowseek.Activity), overrides)
    )
  end

  defp configure(overrides) do
    Application.put_env(
      :knowseek,
      Crawl,
      Keyword.merge(Application.fetch_env!(:knowseek, Crawl), overrides)
    )
  end

  # Options that make `Crawl.due?/1` see an idle instance.
  defp idle_opts do
    now = DateTime.utc_now()
    [now: now, last_search_at: DateTime.add(now, -3_600), cpu: 0.0]
  end

  defp set_links(links) do
    config = Application.get_env(:knowseek, CrawlSource, [])
    Application.put_env(:knowseek, CrawlSource, Keyword.put(config, :links, links))
  end

  defp set_pages(pages) do
    config = Application.get_env(:knowseek, CrawlSource, [])
    Application.put_env(:knowseek, CrawlSource, Keyword.put(config, :pages, pages))
  end

  # The bytes recorded for "crawl": 900 for each read, 800 for each page.
  defp crawl_bytes do
    Repo.aggregate(from(n in NetworkUsage, where: n.source == "crawl"), :sum, :bytes) || 0
  end

  defp link(page_id, title, description \\ nil),
    do: %{page_id: page_id, title: title, description: description}

  # A source page shown at rank 1 of a search with two results (so not alone),
  # by `query`.
  defp source_page(filler, pageid, query, opts \\ []) do
    crawl_source_fixture(
      [pageid: pageid, title: "Source #{pageid}", query: query, alongside: [filler]] ++ opts
    )
  end

  # Stored pages whose text shares three words with "Desem: sourdough starter".
  defp store_near(count) do
    for i <- 1..count, do: document_fixture(body: "Desem sourdough starter notes #{i}")
  end

  defp candidates, do: Repo.all(from c in Candidate, order_by: [c.page_id, c.source_document_id])

  # `CrawlSource` reports 900 bytes for each request.
  defp requests do
    bytes = Repo.aggregate(from(n in NetworkUsage, where: n.source == "crawl"), :sum, :bytes)
    div(bytes || 0, 900)
  end

  defp insert_candidate(source_document_id, page_id, attrs) do
    %{
      source_document_id: source_document_id,
      page_id: page_id,
      site: "crawl",
      title: "Title #{page_id}",
      url: "https://en.wikipedia.org/?curid=#{page_id}",
      interest: 0.9,
      novelty: 1.0,
      score: 0.9,
      state: "pending",
      scored_at: DateTime.utc_now(:second)
    }
    |> Map.merge(Map.new(attrs))
    |> then(&struct!(Candidate, &1))
    |> Repo.insert!()
  end
end
