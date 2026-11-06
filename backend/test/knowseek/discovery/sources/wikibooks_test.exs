defmodule Knowseek.Discovery.Sources.WikibooksTest do
  use Knowseek.DataCase, async: true

  alias Knowseek.Discovery
  alias Knowseek.Discovery.Sources.{Wikibooks, Wikipedia}
  alias Knowseek.Documents

  @fixtures Path.expand("../../../support/fixtures", __DIR__)

  defp fixture(site, name),
    do: [@fixtures, site, name] |> Path.join() |> File.read!() |> Jason.decode!()

  # Answers like the Wikibooks API, from the recorded fixtures.
  defp stub_wikibooks do
    Req.Test.stub(Wikibooks, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(self(), {:wikibooks_request, conn.host, conn.query_params})

      case conn.query_params do
        %{"list" => "search"} -> Req.Test.json(conn, fixture("wikibooks", "search.json"))
        %{"pageids" => id} -> Req.Test.json(conn, fixture("wikibooks", "page_#{id}.json"))
      end
    end)
  end

  defp stub_wikipedia do
    Req.Test.stub(Wikipedia, fn conn ->
      case Plug.Conn.fetch_query_params(conn).query_params do
        %{"list" => "search"} -> Req.Test.json(conn, fixture("wikipedia", "search.json"))
        %{"pageids" => id} -> Req.Test.json(conn, fixture("wikipedia", "page_#{id}.json"))
      end
    end)
  end

  describe "discover/2" do
    test "searches en.wikibooks.org for a question and returns its pages, in search order" do
      stub_wikibooks()

      assert {:ok, [flat, moped]} = Wikibooks.discover("how do i fix a flat tire", [])

      assert_received {:wikibooks_request, "en.wikibooks.org",
                       %{"list" => "search", "srsearch" => "how do i fix a flat tire"}}

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
    end

    test "keeps a page that transcludes only one main-namespace page" do
      Req.Test.stub(Wikibooks, fn conn ->
        case Plug.Conn.fetch_query_params(conn).query_params do
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
end
