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
                         "prop" => "extracts|info|pageprops|pageviews|revisions|extlinks",
                         "ellimit" => "max",
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

  describe "external links" do
    @page 74_020_014
    @links ["http://a.example/1", "https://b.example/2", "//c.example/3"]

    # One page found by the search; `answer` replies to every page request.
    defp stub_pages(answer) do
      Req.Test.stub(Wikipedia, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(self(), {:request, conn.query_params})

        case conn.query_params do
          %{"list" => "search"} ->
            Req.Test.json(conn, %{"query" => %{"search" => [%{"pageid" => @page}]}})

          params ->
            answer.(conn, params)
        end
      end)
    end

    # Answers the first request with `first_links` and, from then on, each
    # `elcontinue` token with the links `continuations` has for it.
    defp stub_continued(first_links, continuations) do
      stub_pages(fn conn, params ->
        case params do
          %{"elcontinue" => token} ->
            {links, next} = Map.fetch!(continuations, token)
            Req.Test.json(conn, with_extlinks(fixture("page_#{@page}.json"), links, next))

          _first ->
            Req.Test.json(
              conn,
              with_extlinks(fixture("page_#{@page}.json"), first_links, "t1")
            )
        end
      end)
    end

    test "a candidate carries its links in page order" do
      stub_pages(fn conn, _params ->
        Req.Test.json(conn, with_extlinks(fixture("page_#{@page}.json"), @links))
      end)

      assert {:ok, [%{links: @links}]} = Wikipedia.discover("pgvector", [])
    end

    test "a page without external links has links: []" do
      stub_api()

      assert {:ok, [vector_db, hnsw]} = Wikipedia.discover("pgvector", [])
      assert vector_db.links == []
      assert hnsw.links == []
    end

    test "follows elcontinue with a request for the links only, and concatenates" do
      stub_continued(["http://a.example/1"], %{
        "t1" => {["http://b.example/2"], "t2"},
        "t2" => {["http://c.example/3"], nil}
      })

      assert {:ok, [%{links: ["http://a.example/1", "http://b.example/2", "http://c.example/3"]}]} =
               Wikipedia.discover("pgvector", [])

      assert_received {:request, %{"list" => "search"}}
      assert_received {:request, %{"explaintext" => "1"}}

      assert_received {:request, continuation}

      assert %{
               "prop" => "extlinks",
               "ellimit" => "max",
               "pageids" => "74020014",
               "elcontinue" => "t1"
             } = continuation

      refute Map.has_key?(continuation, "explaintext")
      refute Map.has_key?(continuation, "rvprop")
      assert_received {:request, %{"elcontinue" => "t2"}}
      refute_received {:request, _}
    end

    test "a failed continuation keeps the page and the links read so far" do
      stub_pages(fn conn, params ->
        case params do
          %{"elcontinue" => _token} ->
            Plug.Conn.send_resp(conn, 500, "")

          _first ->
            Req.Test.json(conn, with_extlinks(fixture("page_#{@page}.json"), @links, "t1"))
        end
      end)

      assert {:ok, [%{title: "Vector database", links: @links}]} =
               Wikipedia.discover("pgvector", [])
    end

    test "no continuation request for a page that yields no candidate" do
      Req.Test.stub(Wikipedia, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(self(), {:request, conn.query_params})

        case conn.query_params do
          %{"list" => "search"} ->
            Req.Test.json(conn, %{"query" => %{"search" => [%{"pageid" => 19_007}]}})

          _page ->
            Req.Test.json(
              conn,
              with_extlinks(fixture("page_19007.json"), ["http://a.example/"], "t1")
            )
        end
      end)

      assert {:ok, []} = Wikipedia.discover("mercury", [])
      assert_received {:request, %{"list" => "search"}}
      assert_received {:request, %{"pageids" => "19007"}}
      refute_received {:request, _}
    end

    test "stops after 10 continuation requests" do
      # Every continuation points at another one.
      stub_pages(fn conn, _params ->
        Req.Test.json(
          conn,
          with_extlinks(fixture("page_#{@page}.json"), ["http://a.example/"], "t")
        )
      end)

      assert {:ok, [%{links: links}]} = Wikipedia.discover("pgvector", [])
      assert length(links) == 11

      requests = for _n <- 1..12, do: receive_request()
      assert Enum.count(requests, &Map.has_key?(&1, "elcontinue")) == 10
      refute_received {:request, _}
    end

    defp receive_request do
      receive do
        {:request, params} -> params
      after
        0 -> %{}
      end
    end
  end

  describe "links/2" do
    @document %{metadata: %{"pageid" => 74_020_014}}

    test "asks for the links of the page by its id, and follows elcontinue" do
      stub_pages(fn conn, params ->
        case params do
          %{"elcontinue" => "t1"} ->
            Req.Test.json(
              conn,
              with_extlinks(fixture("page_#{@page}.json"), ["http://b.example/"])
            )

          _first ->
            Req.Test.json(
              conn,
              with_extlinks(fixture("page_#{@page}.json"), ["http://a.example/"], "t1")
            )
        end
      end)

      assert {:ok, ["http://a.example/", "http://b.example/"]} = Wikipedia.links(@document, [])

      assert_received {:request,
                       %{"prop" => "extlinks", "ellimit" => "max", "pageids" => "74020014"} =
                         first}

      refute Map.has_key?(first, "elcontinue")
      assert_received {:request, %{"elcontinue" => "t1"}}
      refute_received {:request, _}
    end

    test "is {:ok, []} without a page id" do
      assert {:ok, []} = Wikipedia.links(%{metadata: %{}}, [])
      assert {:ok, []} = Wikipedia.links(%{metadata: %{"pageid" => "74020014"}}, [])
    end

    test "is {:ok, []} for a page without external links" do
      stub_pages(fn conn, _params -> Req.Test.json(conn, fixture("page_#{@page}.json")) end)

      assert {:ok, []} = Wikipedia.links(@document, [])
    end

    test "returns the error of a failed request" do
      Req.Test.stub(Wikipedia, &Plug.Conn.send_resp(&1, 503, "unavailable"))

      assert {:error, {:http_status, 503}} = Wikipedia.links(@document, [])
    end
  end

  describe "link_candidates/2" do
    @source %{metadata: %{"pageid" => 74_020_014}}

    # Answers the first request with links_74020014.json and the one with
    # `gplcontinue` with links_74020014_more.json; `answer` can override.
    defp stub_links(answer \\ nil) do
      test_pid = self()

      Req.Test.stub(Wikipedia, fn conn ->
        params = Plug.Conn.fetch_query_params(conn).query_params
        send(test_pid, {:request, params})

        cond do
          answer ->
            answer.(conn, params)

          is_map_key(params, "gplcontinue") ->
            Req.Test.json(conn, fixture("links_74020014_more.json"))

          true ->
            Req.Test.json(conn, fixture("links_74020014.json"))
        end
      end)
    end

    test "asks for the same-site links of the page by its id, with descriptions" do
      stub_links(fn conn, _params -> Req.Test.json(conn, fixture("links_74020014_more.json")) end)

      assert {:ok, _} = Wikipedia.link_candidates(@source, [])

      assert_received {:request, params}

      assert %{
               "generator" => "links",
               "pageids" => "74020014",
               "gpllimit" => "max",
               "gplnamespace" => "0",
               "prop" => "description|pageprops",
               "ppprop" => "disambiguation",
               "redirects" => "1"
             } = params

      refute_received {:request, _}
    end

    test "keeps real main-namespace pages, once each, and leaves out the page itself" do
      stub_links()

      assert {:ok, candidates} = Wikipedia.link_candidates(@source, [])

      assert candidates == [
               %{
                 page_id: 5001,
                 title: "Approximate nearest neighbor search",
                 description: "Algorithmic problem",
                 url: "https://en.wikipedia.org/?curid=5001"
               },
               %{
                 page_id: 5002,
                 title: "Nearest neighbor search",
                 description: "Optimization problem",
                 url: "https://en.wikipedia.org/?curid=5002"
               },
               %{
                 page_id: 5003,
                 title: "Locality-sensitive hashing",
                 description: nil,
                 url: "https://en.wikipedia.org/?curid=5003"
               },
               %{
                 page_id: 5004,
                 title: "Vector database",
                 description: "Database for embeddings",
                 url: "https://en.wikipedia.org/?curid=5004"
               }
             ]
    end

    test "follows continue with gplcontinue, in two requests at most" do
      stub_links(fn conn, _params ->
        # Every answer says there is more.
        continue = %{"gplcontinue" => "x|0|Y", "continue" => "gplcontinue||"}
        body = Map.put(fixture("links_74020014_more.json"), "continue", continue)
        Req.Test.json(conn, body)
      end)

      assert {:ok, [_ | _]} = Wikipedia.link_candidates(@source, [])

      assert_received {:request, first}
      refute Map.has_key?(first, "gplcontinue")
      assert_received {:request, %{"gplcontinue" => "x|0|Y", "generator" => "links"}}
      refute_received {:request, _}
    end

    test "sends the continuation request with the first response's gplcontinue" do
      stub_links()

      assert {:ok, _} = Wikipedia.link_candidates(@source, [])

      assert_received {:request, first}
      refute Map.has_key?(first, "gplcontinue")
      assert_received {:request, %{"gplcontinue" => "74020014|0|Zebra", "pageids" => "74020014"}}
      refute_received {:request, _}
    end

    test "sends no second request when the first response has no continue" do
      stub_links(fn conn, _params -> Req.Test.json(conn, fixture("links_74020014_more.json")) end)

      assert {:ok, [_ | _]} = Wikipedia.link_candidates(@source, [])

      assert_received {:request, _}
      refute_received {:request, _}
    end

    test "keeps the first pages when the second request fails" do
      stub_links(fn conn, params ->
        if is_map_key(params, "gplcontinue"),
          do: Plug.Conn.send_resp(conn, 503, "unavailable"),
          else: Req.Test.json(conn, fixture("links_74020014.json"))
      end)

      assert {:ok, candidates} = Wikipedia.link_candidates(@source, [])
      assert Enum.map(candidates, & &1.page_id) == [5001, 5002]
    end

    test "returns the error of a failed first request" do
      Req.Test.stub(Wikipedia, &Plug.Conn.send_resp(&1, 503, "unavailable"))

      assert {:error, {:http_status, 503}} = Wikipedia.link_candidates(@source, [])
    end

    test "is {:ok, []} for a body without query" do
      stub_links(fn conn, _params -> Req.Test.json(conn, %{"batchcomplete" => true}) end)

      assert {:ok, []} = Wikipedia.link_candidates(@source, [])
    end

    test "sends no request for a document without a page id" do
      stub_links()

      assert {:ok, []} = Wikipedia.link_candidates(%{metadata: %{}}, [])
      assert {:ok, []} = Wikipedia.link_candidates(%{metadata: %{"pageid" => "74020014"}}, [])
      refute_received {:request, _}
    end

    test "reports the size of every response body to :on_bytes" do
      test_pid = self()

      Req.Test.stub(Wikipedia, fn conn ->
        body =
          if is_map_key(Plug.Conn.fetch_query_params(conn).query_params, "gplcontinue"),
            do: fixture("links_74020014_more.json"),
            else: fixture("links_74020014.json")

        json = Jason.encode!(body)
        send(test_pid, {:sent, byte_size(json)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, json)
      end)

      assert {:ok, [_ | _]} =
               Wikipedia.link_candidates(@source, on_bytes: &send(test_pid, {:bytes, &1}))

      sent = messages(:sent)
      assert length(sent) == 2
      assert messages(:bytes) == sent

      assert {:ok, [_ | _]} = Wikipedia.link_candidates(@source, [])
    end
  end

  describe "page/2" do
    test "returns the same candidate as discover/2 for that page" do
      stub_api()
      assert {:ok, [vector_db, _hnsw]} = Wikipedia.discover("pgvector", [])

      assert {:ok, ^vector_db} = Wikipedia.page(74_020_014, [])
    end

    test "sends one request for the page, with its text and a User-Agent" do
      stub_api()

      assert {:ok, %{links: []}} = Wikipedia.page(74_020_014, [])

      assert_received {:request, params, [user_agent]}
      assert user_agent =~ "Knowseek"
      assert %{"pageids" => "74020014", "explaintext" => "1", "ellimit" => "max"} = params
      assert params["prop"] =~ "extracts"
      refute_received {:request, _params, _agent}
    end

    test "is {:ok, nil} for a missing page and for a disambiguation page" do
      stub_api()

      assert {:ok, nil} = Wikipedia.page(1, [])
      assert {:ok, nil} = Wikipedia.page(19_007, [])
    end

    test "returns the error of a failed request" do
      Req.Test.stub(Wikipedia, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, {:http_status, 404}} = Wikipedia.page(74_020_014, [])
    end

    test "reports the size of the response body to :on_bytes" do
      test_pid = self()

      Req.Test.stub(Wikipedia, fn conn ->
        json = Jason.encode!(fixture("page_74020014.json"))
        send(test_pid, {:sent, byte_size(json)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, json)
      end)

      assert {:ok, %{}} = Wikipedia.page(74_020_014, on_bytes: &send(test_pid, {:bytes, &1}))

      assert [size] = messages(:sent)
      assert messages(:bytes) == [size]
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
