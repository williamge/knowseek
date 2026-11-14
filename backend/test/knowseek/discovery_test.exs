defmodule Knowseek.DiscoveryTest do
  # SeekWorker tests change the global source list.
  use Knowseek.DataCase, async: false

  alias Knowseek.Activity.NetworkUsage
  alias Knowseek.Discovery

  alias Knowseek.Discovery.{
    BadCandidateSource,
    BlockedLink,
    CountingFailingSource,
    CountingSource,
    CrawlSource,
    FailingSource,
    FakeSource,
    LinkBackfillWorker,
    LinkSource,
    SeekWorker
  }

  alias Knowseek.Documents

  describe "request/1" do
    test "enqueues a seek job with the normalized query" do
      {:ok, _job} = Discovery.request("  Rust   ASYNC ")
      assert_enqueued(worker: SeekWorker, args: %{"query" => "rust async"})
    end

    test "deduplicates the same query" do
      {:ok, first} = Discovery.request("rust async")
      {:ok, second} = Discovery.request("Rust async")

      assert second.conflict?
      assert second.id == first.id
    end
  end

  describe "SeekWorker" do
    setup do
      config = Application.fetch_env!(:knowseek, Discovery)
      on_exit(fn -> Application.put_env(:knowseek, Discovery, config) end)

      %{
        put_sources: &Application.put_env(:knowseek, Discovery, Keyword.put(config, :sources, &1))
      }
    end

    test "nothing found is :ok" do
      assert :ok = perform_job(SeekWorker, %{"query" => "tide pools"})
    end

    test "a failing source alone is :ok", %{put_sources: put_sources} do
      put_sources.([FailingSource])
      assert :ok = perform_job(SeekWorker, %{"query" => "tide pools"})
    end

    test "some ingested and some failed is :ok", %{put_sources: put_sources} do
      put_sources.([FakeSource, BadCandidateSource])
      assert :ok = perform_job(SeekWorker, %{"query" => "tide pools"})
    end

    test "every candidate failing to ingest returns an error so Oban retries", %{
      put_sources: put_sources
    } do
      put_sources.([BadCandidateSource])

      assert {:error, {:all_ingests_failed, 1}} =
               perform_job(SeekWorker, %{"query" => "tide pools"})
    end
  end

  describe "run/2" do
    test "ingests candidates from every source and tags them with the source name" do
      assert {:ok, %{ingested: 1, failed: 0}} =
               Discovery.run("tide pools", sources: [FakeSource, FailingSource])

      assert [%{source: "fake", title: "About tide pools"}] = Documents.list_documents()
    end

    test "the ingested documents come from a search, with the query" do
      assert {:ok, %{ingested: 1}} = Discovery.run("tide pools", sources: [FakeSource])

      assert [%{origin: "search", origin_query: "tide pools"}] = Documents.list_documents()
    end

    test "a query over 500 characters is cut in origin_query" do
      query = String.duplicate("a", 600)

      assert {:ok, %{ingested: 1}} = Discovery.run(query, sources: [FakeSource])

      assert [%{origin_query: origin_query}] = Documents.list_documents()
      assert origin_query == String.duplicate("a", 500)
    end

    test "records the bytes a source reports, once, under its name" do
      assert {:ok, %{ingested: 1}} = Discovery.run("tide pools", sources: [CountingSource])

      today = Date.utc_today()

      assert [%NetworkUsage{day: ^today, source: "counting", bytes: 2_000}] =
               Repo.all(NetworkUsage)
    end

    test "records the bytes of a source that failed, and the run still succeeds" do
      assert {:ok, %{ingested: 0, failed: 0}} =
               Discovery.run("tide pools", sources: [CountingFailingSource])

      assert [%NetworkUsage{source: "counting_failing", bytes: 500}] = Repo.all(NetworkUsage)
    end

    test "a source that reports nothing leaves no row" do
      assert {:ok, %{ingested: 1}} = Discovery.run("tide pools", sources: [FakeSource])

      assert Repo.all(NetworkUsage) == []
    end

    test "logs the blocked links of a candidate, and ingests it without them" do
      assert {:ok, %{ingested: 1, failed: 0}} =
               Discovery.run("tide pools", sources: [LinkSource])

      assert [%{id: id}] = Documents.list_documents()

      assert [
               %{url: "http://www.example.org/b", host: "example.org", times_seen: 1},
               %{url: "https://example.org/a", host: "example.org", times_seen: 1}
             ] = blocked_links(id)
    end

    test "a second run counts the links again and keeps first_seen_at" do
      {:ok, _summary} = Discovery.run("tide pools", sources: [LinkSource])
      [%{id: id}] = Documents.list_documents()
      past = ~U[2020-01-01 00:00:00Z]
      Repo.update_all(BlockedLink, set: [first_seen_at: past])

      {:ok, _summary} = Discovery.run("tide pools", sources: [LinkSource])

      assert [%{times_seen: 2, first_seen_at: ^past}, %{times_seen: 2, first_seen_at: ^past}] =
               blocked_links(id)
    end
  end

  describe "allowed?/1 and allowed_hosts/0" do
    test "the gate for a crawler" do
      assert Discovery.allowed_hosts() == ["en.wikipedia.org", "en.wikibooks.org"]
      assert Discovery.allowed?("https://en.wikipedia.org/wiki/Kelp")
      refute Discovery.allowed?("https://example.org/")
    end
  end

  describe "record_links/3" do
    setup do
      %{document: document_fixture()}
    end

    test "logs the blocked links and returns their count", %{document: document} do
      urls = [
        "https://a.example/1",
        "//b.example/2",
        "https://en.wikipedia.org/wiki/Kelp",
        "mailto:x@a.example",
        "not a url"
      ]

      assert {:ok, 2} = Discovery.record_links(document.id, urls)

      assert [
               %{url: "https://a.example/1", host: "a.example", times_seen: 1},
               %{url: "https://b.example/2", host: "b.example", times_seen: 1}
             ] = blocked_links(document.id)
    end

    test "dedupes a repeated URL", %{document: document} do
      assert {:ok, 1} =
               Discovery.record_links(document.id, [
                 "https://a.example/1",
                 "https://A.example/1#frag",
                 "https://a.example/1"
               ])

      assert [%{times_seen: 1}] = blocked_links(document.id)
    end

    test "is {:ok, 0} for no links, and for links that are all allowed", %{document: document} do
      assert {:ok, 0} = Discovery.record_links(document.id, [])
      assert {:ok, 0} = Discovery.record_links(document.id, ["https://en.wikibooks.org/wiki/X"])
      assert blocked_links(document.id) == []
    end

    test "counts a link again, and with count: false leaves times_seen", %{document: document} do
      urls = ["https://a.example/1"]

      {:ok, 1} = Discovery.record_links(document.id, urls)
      {:ok, 1} = Discovery.record_links(document.id, urls)
      assert [%{times_seen: 2}] = blocked_links(document.id)

      assert {:ok, 1} = Discovery.record_links(document.id, urls, count: false)
      assert [%{times_seen: 2}] = blocked_links(document.id)
    end

    test "logs more links than one insert chunk", %{document: document} do
      urls = for n <- 1..1_200, do: "https://a.example/#{n}"

      assert {:ok, 1_200} = Discovery.record_links(document.id, urls)
      assert length(blocked_links(document.id)) == 1_200
    end

    test "the rows go when the document goes", %{document: document} do
      {:ok, 1} = Discovery.record_links(document.id, ["https://a.example/1"])

      Repo.delete_all(from d in Documents.Document, where: d.id == ^document.id)

      assert Repo.aggregate(BlockedLink, :count) == 0
    end
  end

  describe "blocked_domains/1" do
    test "groups by host over documents, and counts links, pages and sightings" do
      one = document_fixture()
      two = document_fixture()

      {:ok, 2} = Discovery.record_links(one.id, ["https://a.example/1", "https://a.example/2"])
      {:ok, 1} = Discovery.record_links(two.id, ["https://a.example/1"])
      {:ok, 1} = Discovery.record_links(two.id, ["https://a.example/1"])
      {:ok, 1} = Discovery.record_links(one.id, ["https://b.example/x"])

      Repo.update_all(from(b in BlockedLink, where: b.host == "a.example"),
        set: [first_seen_at: ~U[2026-01-02 03:04:05Z]]
      )

      assert %{
               total_domains: 2,
               total_links: 3,
               domains: [
                 %{
                   host: "a.example",
                   links: 2,
                   pages: 2,
                   times_seen: 4,
                   first_seen_at: ~U[2026-01-02 03:04:05Z],
                   example_url: "https://a.example/1"
                 },
                 %{host: "b.example", links: 1, pages: 1, times_seen: 1}
               ]
             } = Discovery.blocked_domains()
    end

    test "orders by pages, then links, then host" do
      one = document_fixture()
      two = document_fixture()

      {:ok, _} = Discovery.record_links(one.id, ["https://z.example/1", "https://y.example/1"])
      {:ok, _} = Discovery.record_links(one.id, ["https://x.example/1", "https://x.example/2"])
      {:ok, _} = Discovery.record_links(two.id, ["https://z.example/1"])

      assert %{domains: domains} = Discovery.blocked_domains()
      # z: 2 pages; x: 1 page, 2 links; y: 1 page, 1 link.
      assert Enum.map(domains, & &1.host) == ["z.example", "x.example", "y.example"]
    end

    test "respects :limit, and the totals cover the whole log" do
      document = document_fixture()

      {:ok, 3} =
        Discovery.record_links(document.id, [
          "https://a.example/1",
          "https://b.example/1",
          "https://c.example/1"
        ])

      assert %{domains: [%{host: "a.example"}], total_domains: 3, total_links: 3} =
               Discovery.blocked_domains(limit: 1)
    end

    test "an empty log" do
      assert %{domains: [], total_domains: 0, total_links: 0} = Discovery.blocked_domains()
    end
  end

  describe "backfill_links/0" do
    setup do
      config = Application.fetch_env!(:knowseek, Discovery)
      on_exit(fn -> Application.put_env(:knowseek, Discovery, config) end)

      Application.put_env(
        :knowseek,
        Discovery,
        Keyword.put(config, :sources, [FakeSource, LinkSource])
      )
    end

    test "enqueues one job per document of a source with links/2, and none for the others" do
      {:ok, _} = Discovery.run("tide pools", sources: [FakeSource, LinkSource])
      {:ok, _} = Discovery.run("kelp", sources: [LinkSource])
      [fake] = Repo.all(from d in Documents.Document, where: d.source == "fake", select: d.id)
      link_ids = Repo.all(from d in Documents.Document, where: d.source == "links", select: d.id)

      assert {:ok, 2} = Discovery.backfill_links()

      jobs = all_enqueued(worker: LinkBackfillWorker)
      assert jobs |> Enum.map(& &1.args["document_id"]) |> Enum.sort() == Enum.sort(link_ids)
      refute fake in Enum.map(jobs, & &1.args["document_id"])
    end

    test "schedules the jobs apart, two a second, and not all at once" do
      for n <- 1..5, do: document_fixture(source: "links", url: "https://l.example/#{n}")

      assert {:ok, 5} = Discovery.backfill_links()

      times = for job <- all_enqueued(worker: LinkBackfillWorker), do: job.scheduled_at

      assert length(times) == 5
      # Delays of 1, 1, 2, 2 and 3 seconds: the last is 2 seconds after the first.
      assert DateTime.diff(Enum.max(times, DateTime), Enum.min(times, DateTime), :second) >= 2
    end

    test "a second call enqueues no duplicates but still returns the document count" do
      {:ok, _} = Discovery.run("tide pools", sources: [LinkSource])

      assert {:ok, 1} = Discovery.backfill_links()
      assert {:ok, 1} = Discovery.backfill_links()
      assert length(all_enqueued(worker: LinkBackfillWorker)) == 1
    end
  end

  describe "LinkBackfillWorker" do
    setup do
      config = Application.fetch_env!(:knowseek, Discovery)
      on_exit(fn -> Application.put_env(:knowseek, Discovery, config) end)
      Application.put_env(:knowseek, Discovery, Keyword.put(config, :sources, [LinkSource]))
      {:ok, _} = Discovery.run("tide pools", sources: [LinkSource])
      [%{id: id}] = Documents.list_documents()
      %{id: id}
    end

    test "logs the links of the document without counting the ones already logged", %{id: id} do
      assert :ok = perform_job(LinkBackfillWorker, %{"document_id" => id})

      # Two came with the discovery run (times_seen 1, left alone); `links/2`
      # adds a third.
      assert [
               %{times_seen: 1},
               %{times_seen: 1},
               %{times_seen: 1, url: "https://other.example/c"}
             ] =
               blocked_links(id)
    end

    test "the link backfill's downloaded bytes are recorded for its source", %{id: id} do
      assert [] = Repo.all(NetworkUsage)

      assert :ok = perform_job(LinkBackfillWorker, %{"document_id" => id})

      today = Date.utc_today()
      assert [%NetworkUsage{day: ^today, source: "links", bytes: 700}] = Repo.all(NetworkUsage)
    end

    test "is :ok for an unknown document id" do
      assert :ok = perform_job(LinkBackfillWorker, %{"document_id" => Ecto.UUID.generate()})
    end

    test "is :ok for a document whose source has no links/2" do
      document = document_fixture(source: "manual")
      assert :ok = perform_job(LinkBackfillWorker, %{"document_id" => document.id})
      assert blocked_links(document.id) == []
    end

    test "returns the source's error so Oban retries", %{id: id} do
      defmodule ErrorLinks do
        @behaviour Knowseek.Discovery.Source
        def name, do: "links"
        def discover(_query, _opts), do: {:ok, []}
        def links(_document, _opts), do: {:error, :unavailable}
      end

      config = Application.fetch_env!(:knowseek, Discovery)
      Application.put_env(:knowseek, Discovery, Keyword.put(config, :sources, [ErrorLinks]))

      assert {:error, :unavailable} = perform_job(LinkBackfillWorker, %{"document_id" => id})
    end
  end

  describe "link_candidates/1" do
    setup do
      config = Application.fetch_env!(:knowseek, Discovery)

      on_exit(fn ->
        Application.put_env(:knowseek, Discovery, config)
        Application.delete_env(:knowseek, CrawlSource)
      end)

      Application.put_env(
        :knowseek,
        Discovery,
        Keyword.put(config, :sources, [FakeSource, CrawlSource])
      )

      :ok
    end

    test "lists the links of a stored page from its source, and records the bytes" do
      document = crawl_source_fixture(pageid: 7, log: false)

      Application.put_env(:knowseek, CrawlSource,
        links: %{
          7 => [
            %{page_id: 100, title: "Desem", description: "Sourdough starter"},
            %{page_id: 101, title: "Poolish", description: nil}
          ]
        }
      )

      assert {:ok,
              [
                %{
                  page_id: 100,
                  title: "Desem",
                  description: "Sourdough starter",
                  url: "https://en.wikipedia.org/?curid=100"
                },
                %{
                  page_id: 101,
                  title: "Poolish",
                  description: nil,
                  url: "https://en.wikipedia.org/?curid=101"
                }
              ]} = Discovery.link_candidates(document)

      today = Date.utc_today()
      assert [%NetworkUsage{day: ^today, source: "crawl", bytes: 900}] = Repo.all(NetworkUsage)
    end

    test "is {:ok, []} for a document whose source has no link_candidates/2, without a request" do
      fake = document_fixture(source: "fake")
      unknown = document_fixture(source: "not configured")

      assert {:ok, []} = Discovery.link_candidates(fake)
      assert {:ok, []} = Discovery.link_candidates(unknown)
      assert Repo.all(NetworkUsage) == []
    end

    test "is {:ok, []} for a document whose URL is off the allowlist, without a request" do
      document =
        document_fixture(
          source: "crawl",
          url: "https://example.com/page-7",
          metadata: %{"pageid" => 7}
        )

      Application.put_env(:knowseek, CrawlSource,
        links: %{7 => [%{page_id: 100, title: "Desem", description: nil}]}
      )

      assert {:ok, []} = Discovery.link_candidates(document)
      assert Repo.all(NetworkUsage) == []
    end

    test "drops the links whose URL is off the allowlist" do
      document = crawl_source_fixture(pageid: 7, log: false)

      Application.put_env(:knowseek, CrawlSource,
        links: %{
          7 => [
            %{page_id: 100, title: "Desem", description: nil},
            %{page_id: 101, title: "Elsewhere", description: nil, url: "https://example.org/x"},
            %{
              page_id: 102,
              title: "Cookbook",
              description: nil,
              url: "https://en.wikibooks.org/?curid=102"
            }
          ]
        }
      )

      assert {:ok, links} = Discovery.link_candidates(document)
      assert Enum.map(links, & &1.page_id) == [100, 102]
    end

    test "is {:ok, []} for a page without links" do
      document = crawl_source_fixture(pageid: 7, log: false)

      assert {:ok, []} = Discovery.link_candidates(document)
      assert [%NetworkUsage{source: "crawl", bytes: 900}] = Repo.all(NetworkUsage)
    end

    test "returns the source's error, and still records the bytes it downloaded" do
      defmodule ErrorCrawlSource do
        @behaviour Knowseek.Discovery.Source
        def name, do: "crawl"
        def discover(_query, _opts), do: {:ok, []}

        def link_candidates(_document, opts) do
          opts[:on_bytes].(300)
          {:error, :unavailable}
        end

        def page(_page_id, _opts), do: {:error, :unavailable}
      end

      config = Application.fetch_env!(:knowseek, Discovery)
      Application.put_env(:knowseek, Discovery, Keyword.put(config, :sources, [ErrorCrawlSource]))
      document = crawl_source_fixture(pageid: 7, log: false)

      assert {:error, :unavailable} = Discovery.link_candidates(document)
      assert [%NetworkUsage{source: "crawl", bytes: 300}] = Repo.all(NetworkUsage)
    end
  end

  describe "fetch_page/3" do
    @url "https://en.wikipedia.org/?curid=100"

    setup do
      config = Application.fetch_env!(:knowseek, Discovery)

      on_exit(fn ->
        Application.put_env(:knowseek, Discovery, config)
        Application.delete_env(:knowseek, CrawlSource)
      end)

      Application.put_env(
        :knowseek,
        Discovery,
        Keyword.put(config, :sources, [FakeSource, CrawlSource])
      )

      Application.put_env(:knowseek, CrawlSource,
        pages: %{100 => %{title: "Desem", body: "Desem is a sourdough starter."}}
      )

      :ok
    end

    test "ingests the page with origin background and no origin query, and records the bytes" do
      assert {:ok,
              %Documents.Document{
                origin: "background",
                origin_query: nil,
                source: "crawl",
                title: "Desem",
                url: "https://en.wikipedia.org/wiki/Page_100"
              } = document} = Discovery.fetch_page("crawl", 100, @url)

      assert Documents.get_document(document.id)
      today = Date.utc_today()
      assert [%NetworkUsage{day: ^today, source: "crawl", bytes: 800}] = Repo.all(NetworkUsage)
    end

    test "logs the links of the page that go off the allowlist" do
      Application.put_env(:knowseek, CrawlSource,
        pages: %{
          100 => %{
            title: "Desem",
            body: "Desem is a sourdough starter.",
            links: ["https://example.com/a", "https://en.wikipedia.org/wiki/Flour"]
          }
        }
      )

      assert {:ok, document} = Discovery.fetch_page("crawl", 100, @url)

      assert [%BlockedLink{url: "https://example.com/a", host: "example.com"}] =
               blocked_links(document.id)
    end

    test "is {:error, :not_allowed} for a URL off the allowlist, without a request" do
      assert {:error, :not_allowed} =
               Discovery.fetch_page("crawl", 100, "https://example.com/?curid=100")

      assert Repo.all(NetworkUsage) == []
      assert Repo.aggregate(Documents.Document, :count) == 0
    end

    test "is {:error, :not_allowed} when the page's own URL is off the allowlist" do
      Application.put_env(:knowseek, CrawlSource,
        pages: %{
          100 => %{
            title: "Desem",
            body: "Desem is a sourdough starter.",
            url: "https://example.com/desem"
          }
        }
      )

      assert {:error, :not_allowed} = Discovery.fetch_page("crawl", 100, @url)

      assert Repo.aggregate(Documents.Document, :count) == 0
      # The request was made, so its bytes are recorded.
      assert [%NetworkUsage{source: "crawl", bytes: 800}] = Repo.all(NetworkUsage)
    end

    test "passes {:ok, nil} through when the page has no text" do
      assert {:ok, nil} =
               Discovery.fetch_page("crawl", 999, "https://en.wikipedia.org/?curid=999")

      assert Repo.aggregate(Documents.Document, :count) == 0
      assert [%NetworkUsage{source: "crawl", bytes: 800}] = Repo.all(NetworkUsage)
    end

    test "returns a page that is indexed already with its own origin" do
      existing =
        document_fixture(
          source: "crawl",
          origin: "search",
          origin_query: "desem",
          url: "https://en.wikipedia.org/wiki/Page_100",
          body: "Old text."
        )

      assert {:ok, %Documents.Document{id: id, origin: "search", origin_query: "desem"}} =
               Discovery.fetch_page("crawl", 100, @url)

      assert id == existing.id
    end

    test "is {:error, :no_source} for a site that is not configured or cannot fetch pages" do
      assert {:error, :no_source} = Discovery.fetch_page("not configured", 100, @url)
      assert {:error, :no_source} = Discovery.fetch_page("fake", 100, @url)
      assert Repo.all(NetworkUsage) == []
    end

    test "returns the source's error, and still records the bytes it downloaded" do
      Application.put_env(:knowseek, CrawlSource, pages: %{100 => {:error, :unavailable}})

      assert {:error, :unavailable} = Discovery.fetch_page("crawl", 100, @url)
      assert [%NetworkUsage{source: "crawl", bytes: 800}] = Repo.all(NetworkUsage)
    end
  end

  defp blocked_links(document_id),
    do: Repo.all(from b in BlockedLink, where: b.document_id == ^document_id, order_by: b.url)
end
