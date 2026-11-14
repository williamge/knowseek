defmodule Knowseek.Discovery.Sources.WikibooksTest do
  use Knowseek.DataCase, async: false

  alias Knowseek.Discovery
  alias Knowseek.Discovery.Sources.{Wikibooks, Wikipedia}
  alias Knowseek.Documents

  @fixtures Path.expand("../../../support/fixtures", __DIR__)

  defp fixture(site, name),
    do: [@fixtures, site, name] |> Path.join() |> File.read!() |> Jason.decode!()

  # Answers like the Wikibooks API, from the recorded fixtures. The Cookbook
  # search (namespace 102) finds no recipe for "fix a flat tire".
  defp stub_wikibooks do
    Req.Test.stub(Wikibooks, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(self(), {:wikibooks_request, conn.host, conn.query_params})

      case conn.query_params do
        %{"list" => "search", "srnamespace" => "102"} ->
          Req.Test.json(conn, fixture("wikibooks", "search_cookbook_none.json"))

        %{"list" => "search"} ->
          Req.Test.json(conn, fixture("wikibooks", "search.json"))

        %{"pageids" => id} ->
          Req.Test.json(conn, fixture("wikibooks", "page_#{id}.json"))
      end
    end)
  end

  # The Cookbook search finds *Cookbook:Hard Cooked Eggs*; the main-namespace
  # search answers `main_search`.
  defp stub_wikibooks_cookbook(main_search) do
    Req.Test.stub(Wikibooks, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(self(), {:wikibooks_request, conn.host, conn.query_params})

      case conn.query_params do
        %{"list" => "search", "srnamespace" => "102"} ->
          Req.Test.json(conn, fixture("wikibooks", "search_cookbook.json"))

        %{"list" => "search", "srnamespace" => "0"} ->
          Req.Test.json(conn, main_search)

        %{"pageids" => id} ->
          Req.Test.json(conn, fixture("wikibooks", "page_#{id}.json"))
      end
    end)
  end

  defp search_body(pageids),
    do: %{"query" => %{"search" => Enum.map(pageids, &%{"ns" => 0, "pageid" => &1})}}

  defp stub_wikipedia do
    Req.Test.stub(Wikipedia, fn conn ->
      case Plug.Conn.fetch_query_params(conn).query_params do
        %{"list" => "search"} -> Req.Test.json(conn, fixture("wikipedia", "search.json"))
        %{"pageids" => id} -> Req.Test.json(conn, fixture("wikipedia", "page_#{id}.json"))
      end
    end)
  end

  describe "discover/2" do
    test "searches en.wikibooks.org for a question, without its lead-in, and returns its pages, in search order" do
      stub_wikibooks()

      assert {:ok, [flat, moped]} = Wikibooks.discover("how do i fix a flat tire", [])

      assert_received {:wikibooks_request, "en.wikibooks.org",
                       %{
                         "list" => "search",
                         "srsearch" => "fix a flat tire",
                         "srnamespace" => "0"
                       }}

      assert flat.url ==
               "https://en.wikibooks.org/wiki/Bicycles/Maintenance_and_Repair/Wheels_and_Tires/Fixing_a_flat"

      assert flat.title == "Bicycles/Maintenance and Repair/Wheels and Tires/Fixing a flat"
      assert flat.body =~ "how to repair punctures in bicycle inner tubes"
      assert flat.metadata == %{"pageid" => 3567}
      assert moped.title == "Tomos Moped/Repair"
    end

    test "carries CC BY-SA 4.0 with credit to Wikibooks and the page, modified, shared in full" do
      stub_wikibooks()

      assert {:ok, [flat, moped]} = Wikibooks.discover("how do i fix a flat tire", [])

      for candidate <- [flat, moped] do
        assert %{
                 license: "CC-BY-SA-4.0",
                 attribution: %{url: url, credit: "Wikibooks", authors: []},
                 modified: true,
                 share: "full"
               } = candidate

        assert url == candidate.url
      end
    end

    test "carries the page's Wikibooks views per 30 days and its latest revision time" do
      stub_wikibooks()

      assert {:ok, [flat, moped]} = Wikibooks.discover("how do i fix a flat tire", [])

      assert flat.monthly_views == 238
      assert moped.monthly_views == 172
      assert flat.source_updated_at == ~U[2021-08-23 03:29:06Z]
    end

    test "sends no request and returns no candidates for a query that is not a question" do
      stub_wikibooks()

      assert {:ok, []} = Wikibooks.discover("barack obama", [])

      refute_received {:wikibooks_request, _host, _params}
    end

    test "skips a compilation: a page that transcludes 2 or more main-namespace pages" do
      stub_wikibooks()

      # The search's third result is the Tomos Moped print version.
      assert {:ok, candidates} = Wikibooks.discover("how do i fix a flat tire", [])

      assert Enum.map(candidates, & &1.title) == [
               "Bicycles/Maintenance and Repair/Wheels and Tires/Fixing a flat",
               "Tomos Moped/Repair"
             ]

      assert_received {:wikibooks_request, _host,
                       %{"pageids" => "448201", "tlnamespace" => "0", "tllimit" => "2"} = params}

      assert params["prop"] =~ "templates"
      assert String.ends_with?(params["prop"], "|extlinks|templates")
      assert %{"ellimit" => "max"} = params
    end

    test "a response whose continue has only tlcontinue triggers no extra request" do
      # The real Wikibooks shape: `tllimit=2` makes most responses carry a
      # `tlcontinue` and no `elcontinue`.
      Req.Test.stub(Wikibooks, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(self(), {:wikibooks_request, conn.host, conn.query_params})

        case conn.query_params do
          %{"list" => "search", "srnamespace" => "102"} ->
            Req.Test.json(conn, fixture("wikibooks", "search_cookbook_none.json"))

          %{"list" => "search"} ->
            Req.Test.json(conn, search_body([3567]))

          %{"pageids" => "3567"} ->
            body = fixture("wikibooks", "page_3567.json")

            body
            |> Map.put("continue", %{"tlcontinue" => "3567|0|Page", "continue" => "||extracts"})
            |> with_extlinks(["https://example.org/a", "https://example.org/b"])
            |> then(&Req.Test.json(conn, &1))
        end
      end)

      assert {:ok, [%{links: ["https://example.org/a", "https://example.org/b"]}]} =
               Wikibooks.discover("how do i fix a flat tire", [])

      assert_received {:wikibooks_request, _host, %{"pageids" => "3567"}}
      refute_received {:wikibooks_request, _host, %{"elcontinue" => _token}}
      refute_received {:wikibooks_request, _host, %{"pageids" => _id}}
    end

    test "links/2 asks Wikibooks for the page's external links by its id" do
      Req.Test.stub(Wikibooks, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(self(), {:wikibooks_request, conn.host, conn.query_params})

        Req.Test.json(
          conn,
          with_extlinks(fixture("wikibooks", "page_3567.json"), ["http://a.example/"])
        )
      end)

      assert {:ok, ["http://a.example/"]} = Wikibooks.links(%{metadata: %{"pageid" => 3567}}, [])

      assert_received {:wikibooks_request, "en.wikibooks.org",
                       %{"prop" => "extlinks", "pageids" => "3567"}}
    end

    test "keeps a page that transcludes only one main-namespace page" do
      Req.Test.stub(Wikibooks, fn conn ->
        case Plug.Conn.fetch_query_params(conn).query_params do
          %{"list" => "search", "srnamespace" => "102"} ->
            Req.Test.json(conn, fixture("wikibooks", "search_cookbook_none.json"))

          %{"list" => "search"} ->
            Req.Test.json(conn, fixture("wikibooks", "search.json"))

          %{"pageids" => "448201"} ->
            Req.Test.json(conn, fixture("wikibooks", "page_448201.json"))

          %{"pageids" => id} ->
            body = fixture("wikibooks", "page_#{id}.json")
            shared = [%{"ns" => 0, "title" => "Bicycles/Shared notice"}]

            Req.Test.json(
              conn,
              put_in(body, ["query", "pages", Access.at(0), "templates"], shared)
            )
        end
      end)

      assert {:ok, [_flat, _moped]} = Wikibooks.discover("how do i fix a flat tire", [])
    end

    test "Wikipedia does not ask for transclusions and keeps every page" do
      Req.Test.stub(Wikipedia, fn conn ->
        params = Plug.Conn.fetch_query_params(conn).query_params
        send(self(), {:wikipedia_request, params})

        case params do
          %{"list" => "search"} -> Req.Test.json(conn, fixture("wikipedia", "search.json"))
          %{"pageids" => id} -> Req.Test.json(conn, fixture("wikipedia", "page_#{id}.json"))
        end
      end)

      assert {:ok, [_one, _two]} = Wikipedia.discover("flat tire", [])

      assert_received {:wikipedia_request, %{"pageids" => _id} = params}
      refute params["prop"] =~ "templates"
      refute Map.has_key?(params, "tlnamespace")
    end

    test "Wikipedia sends one search, in the main namespace" do
      Req.Test.stub(Wikipedia, fn conn ->
        params = Plug.Conn.fetch_query_params(conn).query_params
        send(self(), {:wikipedia_request, params})

        case params do
          %{"list" => "search"} -> Req.Test.json(conn, fixture("wikipedia", "search.json"))
          %{"pageids" => id} -> Req.Test.json(conn, fixture("wikipedia", "page_#{id}.json"))
        end
      end)

      assert {:ok, [_one, _two]} = Wikipedia.discover("how do i cook eggs", [])

      assert_received {:wikipedia_request, %{"list" => "search", "srnamespace" => "0"}}
      refute_received {:wikipedia_request, %{"list" => "search"}}
    end

    test "searches the Cookbook, then the main namespace, for a question" do
      stub_wikibooks()

      assert {:ok, [_flat, _moped]} = Wikibooks.discover("how do i fix a flat tire", [])

      assert_received {:wikibooks_request, "en.wikibooks.org",
                       %{
                         "list" => "search",
                         "srsearch" => "fix a flat tire",
                         "srnamespace" => "102"
                       } =
                         cookbook}

      assert_received {:wikibooks_request, "en.wikibooks.org",
                       %{"list" => "search", "srnamespace" => "0"}}

      assert %{"srlimit" => "3", "maxlag" => "5"} = cookbook
    end

    test "puts Cookbook recipes first, then main-namespace pages, cut to 3" do
      stub_wikibooks_cookbook(fixture("wikibooks", "search.json"))

      assert {:ok, candidates} = Wikibooks.discover("how do i cook eggs", [])

      assert Enum.map(candidates, & &1.title) == [
               "Cookbook:Hard Cooked Eggs",
               "Bicycles/Maintenance and Repair/Wheels and Tires/Fixing a flat",
               "Tomos Moped/Repair"
             ]

      # The main search's third page is past the cut: it is not fetched.
      refute_received {:wikibooks_request, _host, %{"pageids" => "448201"}}
    end

    test "returns a recipe with its Cookbook: title, credited to Wikibooks like other pages" do
      stub_wikibooks_cookbook(search_body([]))

      assert {:ok, [recipe]} = Wikibooks.discover("how do i cook eggs", [])

      assert %{
               title: "Cookbook:Hard Cooked Eggs",
               url: "https://en.wikibooks.org/wiki/Cookbook:Hard_Cooked_Eggs",
               metadata: %{"pageid" => 123_791},
               license: "CC-BY-SA-4.0",
               attribution: %{
                 url: "https://en.wikibooks.org/wiki/Cookbook:Hard_Cooked_Eggs",
                 credit: "Wikibooks",
                 authors: []
               },
               modified: true,
               share: "full",
               monthly_views: 118,
               source_updated_at: ~U[2025-06-08 13:32:52Z]
             } = recipe

      assert recipe.body =~ "Bring to a rolling boil."

      # Recipes are checked for compilations too.
      assert_received {:wikibooks_request, _host,
                       %{"pageids" => "123791", "tlnamespace" => "0"} = params}

      assert params["prop"] =~ "templates"
    end

    test "drops a page that both searches return" do
      stub_wikibooks_cookbook(search_body([123_791, 3567]))

      assert {:ok, candidates} = Wikibooks.discover("how do i cook eggs", [])

      assert Enum.map(candidates, & &1.title) == [
               "Cookbook:Hard Cooked Eggs",
               "Bicycles/Maintenance and Repair/Wheels and Tires/Fixing a flat"
             ]
    end

    test "returns the error when the Cookbook search fails" do
      Req.Test.stub(Wikibooks, fn conn ->
        case Plug.Conn.fetch_query_params(conn).query_params do
          %{"list" => "search", "srnamespace" => "102"} ->
            Req.Test.json(conn, %{"error" => %{"code" => "maxlag"}})

          %{"list" => "search"} ->
            Req.Test.json(conn, fixture("wikibooks", "search.json"))
        end
      end)

      assert {:error, {:api_error, "maxlag"}} = Wikibooks.discover("how do i cook eggs", [])
    end
  end

  describe "link_candidates/2" do
    test "asks for the main and Cookbook namespaces and keeps a Cookbook page" do
      test_pid = self()

      Req.Test.stub(Wikibooks, fn conn ->
        params = Plug.Conn.fetch_query_params(conn).query_params
        send(test_pid, {:request, conn.host, params})

        Req.Test.json(conn, %{
          "query" => %{
            "pages" => [
              %{
                "pageid" => 11,
                "ns" => 102,
                "title" => "Cookbook:Bread",
                "description" => "Baked food"
              },
              %{"pageid" => 12, "ns" => 0, "title" => "Bread baking"},
              %{"pageid" => 13, "ns" => 4, "title" => "Wikibooks:Help"},
              %{"pageid" => 99, "ns" => 0, "title" => "The book itself"}
            ]
          }
        })
      end)

      assert {:ok, candidates} =
               Wikibooks.link_candidates(%{metadata: %{"pageid" => 99}}, [])

      assert_received {:request, "en.wikibooks.org",
                       %{"generator" => "links", "pageids" => "99", "gplnamespace" => "0|102"}}

      assert candidates == [
               %{
                 page_id: 11,
                 title: "Cookbook:Bread",
                 description: "Baked food",
                 url: "https://en.wikibooks.org/?curid=11"
               },
               %{
                 page_id: 12,
                 title: "Bread baking",
                 description: nil,
                 url: "https://en.wikibooks.org/?curid=12"
               }
             ]
    end

    test "sends no request for a document without a page id" do
      Req.Test.stub(Wikibooks, fn conn ->
        send(self(), :request)
        Req.Test.json(conn, %{})
      end)

      assert {:ok, []} = Wikibooks.link_candidates(%{metadata: %{}}, [])
      refute_received :request
    end
  end

  describe "page/2" do
    test "fetches one page by its id on Wikibooks, as discover/2 would" do
      stub_wikibooks()

      assert {:ok, %{url: "https://en.wikibooks.org/" <> _} = candidate} =
               Wikibooks.page(123_791, [])

      assert candidate.title == "Cookbook:Hard Cooked Eggs"
      assert candidate.metadata == %{"pageid" => 123_791}
      assert_received {:wikibooks_request, "en.wikibooks.org", %{"pageids" => "123791"}}
    end

    test "is {:ok, nil} for a compilation" do
      stub_wikibooks()

      assert {:ok, nil} = Wikibooks.page(448_201, [])
    end
  end

  describe "with Discovery.run/2" do
    test "ingests a question's pages as wikibooks documents, next to Wikipedia's" do
      stub_wikibooks()
      stub_wikipedia()

      assert {:ok, %{ingested: 4, failed: 0}} =
               Discovery.run("how do i fix a flat tire", sources: [Wikipedia, Wikibooks])

      documents = Documents.list_documents()

      assert documents |> Enum.map(& &1.source) |> Enum.frequencies() == %{
               "wikibooks" => 2,
               "wikipedia" => 2
             }

      assert %{license: "CC-BY-SA-4.0", share: "full", modified: true, attribution: attribution} =
               Enum.find(documents, &(&1.source == "wikibooks" and &1.title =~ "Fixing a flat"))

      assert %{credit: "Wikibooks"} = attribution
    end

    test "ingests a recipe as a wikibooks document with its Cookbook: title" do
      stub_wikibooks_cookbook(search_body([]))

      assert {:ok, %{ingested: 1, failed: 0}} =
               Discovery.run("how do i cook eggs", sources: [Wikibooks])

      assert [%{source: "wikibooks", title: "Cookbook:Hard Cooked Eggs"}] =
               Documents.list_documents()
    end

    test "runs only Wikipedia for a query that is not a question" do
      stub_wikibooks()
      stub_wikipedia()

      assert {:ok, %{ingested: 2, failed: 0}} =
               Discovery.run("barack obama", sources: [Wikipedia, Wikibooks])

      assert Enum.all?(Documents.list_documents(), &(&1.source == "wikipedia"))
      refute_received {:wikibooks_request, _host, _params}
    end
  end

  describe "question?/1" do
    test "is true for a query that starts with a question word, in any case" do
      for query <- [
            "how do I fix a flat tire",
            "How to tie a bowline",
            "how-to bake bread",
            "why does my bike chain slip",
            "can I freeze bread",
            "could I reuse a tube",
            "should I patch or replace a tube",
            "do I need a torque wrench",
            "Is it safe to ride on a patched tube",
            "what's the best way to learn knots",
            "what’s the best glue for rubber",
            "whats the best tire lever",
            "WHAT IS THE BEST bike pump"
          ] do
        assert Wikibooks.question?(query), query
      end
    end

    test "is true for a query that ends with a question mark" do
      assert Wikibooks.question?("who wrote dune?")
      assert Wikibooks.question?("  flat tire ?  ")
    end

    test "is false for a name, a subject, or a question word inside another word" do
      for query <- [
            "Barack Obama",
            "flat tire",
            "what is a bowline",
            "howard carter",
            "cannes film festival",
            "dolphins",
            "issue tracker",
            ""
          ] do
        refute Wikibooks.question?(query), query
      end
    end
  end

  describe "search_text/1" do
    test "drops the question lead-in and a trailing question mark" do
      for {query, text} <- [
            {"how do i cook eggs", "cook eggs"},
            {"How do I fix a flat tire?", "fix a flat tire"},
            {"how to tie a bowline", "tie a bowline"},
            {"how-to bake bread", "bake bread"},
            {"how does a carburetor work", "a carburetor work"},
            {"why does my bike chain slip", "my bike chain slip"},
            {"can I freeze bread", "freeze bread"},
            {"should I patch or replace a tube", "patch or replace a tube"},
            {"do I need a torque wrench", "need a torque wrench"},
            {"Is it safe to ride on a patched tube", "safe to ride on a patched tube"},
            {"what's the best way to learn knots", "learn knots"},
            {"whats the best tire lever", "tire lever"},
            {"WHAT IS THE BEST bike pump", "bike pump"},
            {"who wrote dune?", "who wrote dune"}
          ] do
        assert Wikibooks.search_text(query) == text, query
      end
    end

    test "keeps the query when nothing would be left" do
      assert Wikibooks.search_text("how?") == "how?"
      assert Wikibooks.search_text("  how do i  ") == "how do i"
    end
  end
end
