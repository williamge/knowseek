defmodule Knowseek.Discovery.Sources.WikipediaTest do
  use Knowseek.DataCase, async: true

  alias Knowseek.Discovery
  alias Knowseek.Discovery.Sources.Wikipedia
  alias Knowseek.Documents

  @fixtures Path.expand("../../../support/fixtures/wikipedia", __DIR__)

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  # Answers like the MediaWiki API, from the recorded fixtures.
  defp stub_api(search \\ fixture("search.json")) do
    Req.Test.stub(Wikipedia, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(self(), {:request, conn.query_params, Plug.Conn.get_req_header(conn, "user-agent")})

      case conn.query_params do
        %{"list" => "search"} -> Req.Test.json(conn, search)
        %{"pageids" => "1"} -> Req.Test.json(conn, fixture("page_missing.json"))
        %{"pageids" => id} -> Req.Test.json(conn, fixture("page_#{id}.json"))
      end
    end)
  end

  describe "discover/2" do
    test "returns one candidate per search result, in search order" do
      stub_api()

      assert {:ok, [vector_db, hnsw]} = Wikipedia.discover("pgvector", [])

      assert vector_db.url == "https://en.wikipedia.org/wiki/Vector_database"
      assert vector_db.title == "Vector database"
      assert vector_db.body =~ "A vector database"
      assert vector_db.metadata == %{"pageid" => 74_020_014}

      assert hnsw.title == "Hierarchical navigable small world"
      assert hnsw.metadata == %{"pageid" => 76_162_223}
    end

    test "carries the page's views per 30 days, and none when the API gave no figure" do
      stub_api()

      assert {:ok, [vector_db, hnsw]} = Wikipedia.discover("pgvector", [])

      # Recorded response: 59 days with data (today's is null), 60 days asked for.
      assert vector_db.monthly_views == 6_752
      refute Map.has_key?(hnsw, :monthly_views)
    end

    test "searches articles, then fetches each page's plain text, with a User-Agent" do
      stub_api()

      {:ok, _candidates} = Wikipedia.discover("pgvector", [])

      assert_received {:request, search, [user_agent]}
      assert user_agent =~ "Knowseek"

      assert %{
               "action" => "query",
               "list" => "search",
               "srsearch" => "pgvector",
               "srnamespace" => "0",
               "formatversion" => "2",
               "maxlag" => "5"
             } = search

      assert_received {:request,
                       %{
                         "prop" => "extracts|info|pageprops|pageviews",
                         "pvipdays" => "60",
                         "explaintext" => "1",
                         "pageids" => "74020014"
                       }, _}

      assert_received {:request, %{"pageids" => "76162223"}, _}
    end

    test "skips pages that are missing" do
      stub_api(%{"query" => %{"search" => [%{"pageid" => 1}, %{"pageid" => 74_020_014}]}})

      assert {:ok, [%{title: "Vector database"}]} = Wikipedia.discover("pgvector", [])
    end

    test "skips disambiguation pages" do
      stub_api(%{"query" => %{"search" => [%{"pageid" => 19_007}, %{"pageid" => 74_020_014}]}})

      assert {:ok, [%{title: "Vector database"}]} = Wikipedia.discover("mercury", [])
    end

    test "cuts a long query to the CirrusSearch limit" do
      stub_api()

      {:ok, _candidates} = Wikipedia.discover(String.duplicate("octopus ", 45), [])

      assert_received {:request, %{"list" => "search", "srsearch" => srsearch}, _}
      assert String.length(srsearch) <= 300
    end

    test "returns no candidates when the search finds nothing" do
      stub_api(%{"query" => %{"searchinfo" => %{"totalhits" => 0}, "search" => []}})

      assert {:ok, []} = Wikipedia.discover("zzzxqv", [])
    end

    test "returns an error for a non-200 response" do
      Req.Test.stub(Wikipedia, &Plug.Conn.send_resp(&1, 503, "unavailable"))

      assert {:error, {:http_status, 503}} = Wikipedia.discover("pgvector", [])
    end

    test "keeps the other pages when one page fetch fails" do
      Req.Test.stub(Wikipedia, fn conn ->
        case Plug.Conn.fetch_query_params(conn).query_params do
          %{"list" => "search"} -> Req.Test.json(conn, fixture("search.json"))
          %{"pageids" => "74020014"} -> Plug.Conn.send_resp(conn, 500, "")
          %{"pageids" => id} -> Req.Test.json(conn, fixture("page_#{id}.json"))
        end
      end)

      assert {:ok, [%{title: "Hierarchical navigable small world"}]} =
               Wikipedia.discover("pgvector", [])
    end

    test "returns an error when every page fetch fails" do
      Req.Test.stub(Wikipedia, fn conn ->
        case Plug.Conn.fetch_query_params(conn).query_params do
          %{"list" => "search"} -> Req.Test.json(conn, fixture("search.json"))
          _page -> Plug.Conn.send_resp(conn, 500, "")
        end
      end)

      assert {:error, {:http_status, 500}} = Wikipedia.discover("pgvector", [])
    end

    test "returns an error when the search response has no results list" do
      stub_api(%{"batchcomplete" => true})

      assert {:error, :unexpected_body} = Wikipedia.discover("pgvector", [])
    end

    test "returns an error when a page response has no pages list" do
      Req.Test.stub(Wikipedia, fn conn ->
        case Plug.Conn.fetch_query_params(conn).query_params do
          %{"list" => "search"} -> Req.Test.json(conn, fixture("search.json"))
          _page -> Req.Test.json(conn, %{"batchcomplete" => true})
        end
      end)

      assert {:error, :unexpected_body} = Wikipedia.discover("pgvector", [])
    end

    test "returns an error for a timeout" do
      Req.Test.stub(Wikipedia, &Req.Test.transport_error(&1, :timeout))

      assert {:error, %Req.TransportError{reason: :timeout}} = Wikipedia.discover("pgvector", [])
    end

    test "returns an error when the API reports one" do
      stub_api(fixture("error_missingparam.json"))

      assert {:error, {:api_error, "missingparam"}} = Wikipedia.discover("", [])
    end
  end

  describe "truncate/2" do
    test "keeps a body that fits" do
      assert Wikipedia.truncate("short", 10) == "short"
    end

    test "cuts at the last paragraph break before the limit" do
      body = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
      assert Wikipedia.truncate(body, 40) == "First paragraph.\n\nSecond paragraph."
    end

    test "cuts at the limit when there is no paragraph break" do
      assert Wikipedia.truncate("abcdefghij", 4) == "abcd"
    end

    test "cuts at the limit when the last paragraph break is in the first half" do
      body = "Lead.\n\n" <> String.duplicate("x", 100)
      assert Wikipedia.truncate(body, 50) == String.slice(body, 0, 50)
    end
  end

  describe "search_text/1" do
    test "keeps a query that fits" do
      assert Wikipedia.search_text("octopus intelligence") == "octopus intelligence"
    end

    test "cuts a long query at the last word boundary before 300 code points" do
      query = String.duplicate("octopus ", 45)
      text = Wikipedia.search_text(query)

      assert String.length(text) <= 300
      assert String.ends_with?(text, "octopus")
    end

    test "cuts at 300 code points when there is no space" do
      assert "x" |> String.duplicate(400) |> Wikipedia.search_text() |> String.length() == 300
    end

    test "counts code points, not graphemes" do
      # "é" as "e" plus a combining accent: one grapheme, two code points.
      text = "e\u0301" |> String.duplicate(200) |> Wikipedia.search_text()

      assert length(String.codepoints(text)) == 300
    end
  end

  describe "monthly_views/1" do
    test "averages the days with data and scales to 30 days" do
      assert Wikipedia.monthly_views(%{"2026-10-01" => 100, "2026-10-02" => 200}) == 4_500
    end

    test "ignores days without data" do
      assert Wikipedia.monthly_views(%{"2026-10-01" => 100, "2026-10-02" => nil}) == 3_000
    end

    test "is nil when no day has data or the API sent nothing" do
      assert Wikipedia.monthly_views(%{"2026-10-01" => nil}) == nil
      assert Wikipedia.monthly_views(%{}) == nil
      assert Wikipedia.monthly_views(nil) == nil
    end

    test "a page with zero views has zero" do
      assert Wikipedia.monthly_views(%{"2026-10-01" => 0}) == 0
    end
  end

  describe "with Discovery.run/2" do
    test "ingests the pages as wikipedia documents" do
      stub_api()

      assert {:ok, %{ingested: 2, failed: 0}} = Discovery.run("pgvector", sources: [Wikipedia])

      assert [_, _] = documents = Documents.list_documents()
      assert Enum.all?(documents, &(&1.source == "wikipedia"))

      assert %{monthly_views: 6_752} = Enum.find(documents, &(&1.title == "Vector database"))
      assert %{monthly_views: nil} = Enum.find(documents, &(&1.title =~ "small world"))
    end
  end
end
