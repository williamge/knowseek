defmodule Knowseek.Discovery.Sources.WikipediaTest do
  use Knowseek.DataCase, async: false

  alias Knowseek.Discovery
  alias Knowseek.Discovery.Sources.Wikipedia
  alias Knowseek.Documents

  @fixtures Path.expand("../../../support/fixtures/wikipedia", __DIR__)

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  # The payloads of the `{tag, payload}` messages in the test's mailbox, in order.
  defp messages(tag) do
    receive do
      {^tag, payload} -> [payload | messages(tag)]
    after
      0 -> []
    end
  end

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

    test "carries the latest revision time as source_updated_at, and none without one" do
      stub_api()

      assert {:ok, [vector_db, hnsw]} = Wikipedia.discover("pgvector", [])
      assert vector_db.source_updated_at == ~U[2026-09-10 19:31:06Z]
      assert hnsw.source_updated_at == ~U[2026-08-13 02:48:09Z]
    end

    test "carries CC BY-SA 4.0 with credit to the page, modified, shared in full" do
      stub_api()

      assert {:ok, [vector_db | _]} = Wikipedia.discover("pgvector", [])

      assert %{
               license: "CC-BY-SA-4.0",
               attribution: %{url: url, credit: "Wikipedia", authors: []},
               modified: true,
               share: "full"
             } = vector_db

      assert url == vector_db.url
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
                         "prop" => "extracts|info|pageprops|pageviews|revisions",
                         "rvprop" => "timestamp",
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

  describe "discover/2 with :on_bytes" do
    test "reports the size of every response body, and works without it" do
      test_pid = self()

      Req.Test.stub(Wikipedia, fn conn ->
        body =
          case Plug.Conn.fetch_query_params(conn).query_params do
            %{"list" => "search"} -> fixture("search.json")
            %{"pageids" => id} -> fixture("page_#{id}.json")
          end

        json = Jason.encode!(body)
        send(test_pid, {:sent, byte_size(json)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, json)
      end)

      assert {:ok, [_, _]} =
               Wikipedia.discover("pgvector", on_bytes: &send(test_pid, {:bytes, &1}))

      # One search and two pages.
      sent = messages(:sent)
      assert length(sent) == 3
      assert messages(:bytes) == sent

      assert {:ok, [_, _]} = Wikipedia.discover("pgvector", [])
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
