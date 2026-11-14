defmodule KnowseekWeb.StatsControllerTest do
  use KnowseekWeb.ConnCase, async: false

  alias Knowseek.Activity
  alias Knowseek.Crawl.{Candidate, SourcePage}
  alias Knowseek.Repo

  @keys ~w(searches pages passages budget network hit_share gain crawl)

  describe "GET /api/stats" do
    test "has the documented shape on an empty database", %{conn: conn} do
      assert %{"data" => data} = conn |> get(~p"/api/stats") |> json_response(200)

      assert Enum.sort(Map.keys(data)) == Enum.sort(@keys)
      assert data["searches"] == %{"total" => 0, "days" => []}
      assert data["pages"] == %{"search" => 0, "background" => 0, "manual" => 0}
      assert data["network"] == []
      assert data["hit_share"] == %{"background_pages" => 0, "hit_pages" => 0}
      assert data["gain"] == %{"pages" => 0, "searches" => 0, "window_searches" => 0}
      assert data["passages"] == 0
      refute Map.has_key?(data, "disk_bytes")
    end

    test "has the budget", %{conn: conn} do
      assert %{"data" => %{"budget" => budget}} =
               conn |> get(~p"/api/stats") |> json_response(200)

      assert Enum.sort(Map.keys(budget)) == ~w(background_share disk free_disk network)
      assert budget["disk"]["used"] > 0
      assert budget["disk"]["limit"] == 5_000_000_000
      assert budget["disk"]["state"] == "ok"
      assert budget["network"] == %{"used" => 0, "limit" => 200_000_000, "state" => "ok"}
      assert budget["free_disk"] == %{"bytes" => nil, "floor" => 0, "low" => false}
      assert budget["background_share"] == 0.9
    end

    test "counts the passages", %{conn: conn} do
      document_fixture()
      expected = Knowseek.Documents.count_chunks()
      assert expected > 0

      assert %{"data" => %{"passages" => ^expected}} =
               conn |> get(~p"/api/stats") |> json_response(200)
    end

    test "has the gain", %{conn: conn} do
      background = document_fixture(origin: "background")
      other = document_fixture(origin: "search")
      logged_search_fixture(query: "desem", documents: [background, other])
      logged_search_fixture(query: "bread", documents: [other])

      assert %{"data" => %{"gain" => gain}} = conn |> get(~p"/api/stats") |> json_response(200)

      assert gain == %{"pages" => 1, "searches" => 1, "window_searches" => 2}
    end

    test "has the crawl counters", %{conn: conn} do
      assert %{"data" => %{"crawl" => crawl}} = conn |> get(~p"/api/stats") |> json_response(200)

      assert crawl == %{
               "mode" => "off",
               "pages_per_day" => 100,
               "fetched_today" => 0,
               "fetched" => 0,
               "links_read" => 0,
               "candidates" => 0,
               "stored_bytes" => 0
             }
    end

    test "shows a search made through the API, with network and pages", %{conn: conn} do
      document_fixture(origin: "search", origin_query: "q")
      Activity.record_bytes("wikipedia", 1_234)

      conn |> post(~p"/api/search", query: "nothing indexed about this") |> json_response(200)
      _ = :sys.get_state(Activity.Recorder)

      assert %{"data" => data} = conn |> get(~p"/api/stats") |> json_response(200)

      today = Date.to_iso8601(Date.utc_today())

      assert data["searches"] == %{
               "total" => 1,
               "days" => [%{"day" => today, "sufficient" => 0, "partial" => 0, "none" => 1}]
             }

      assert data["pages"] == %{"search" => 1, "background" => 0, "manual" => 0}
      assert data["network"] == [%{"day" => today, "source" => "wikipedia", "bytes" => 1_234}]
    end
  end

  describe "DELETE /api/searches" do
    test "deletes the searches and says how many", %{conn: conn} do
      logged_search_fixture()
      logged_search_fixture()

      assert %{"data" => %{"deleted" => 2}} =
               conn |> delete(~p"/api/searches") |> json_response(200)

      assert %{"data" => %{"searches" => %{"total" => 0, "days" => []}}} =
               conn |> get(~p"/api/stats") |> json_response(200)
    end

    test "removes pending candidates and link lists, and keeps a fetched candidate", %{
      conn: conn
    } do
      source = crawl_source_fixture(log: false)
      now = DateTime.utc_now(:second)

      Repo.insert!(%SourcePage{
        document_id: source.id,
        site: "crawl",
        link_ids: [1, 2],
        links: 2,
        kept: 1,
        read_at: now
      })

      row = %Candidate{
        source_document_id: source.id,
        site: "crawl",
        title: "T",
        url: "https://en.wikipedia.org/?curid=1",
        interest: 0.9,
        novelty: 1.0,
        score: 0.9,
        scored_at: now
      }

      Repo.insert!(%{row | page_id: 1})

      Repo.insert!(%{
        row
        | page_id: 2,
          state: "fetched",
          stored_bytes: 500,
          fetched_at: now
      })

      assert %{"data" => %{"crawl" => %{"candidates" => 1, "links_read" => 2}}} =
               conn |> get(~p"/api/stats") |> json_response(200)

      conn |> delete(~p"/api/searches") |> json_response(200)

      assert Repo.all(SourcePage) == []
      assert [%Candidate{page_id: 2, state: "fetched"}] = Repo.all(Candidate)

      assert %{"data" => %{"crawl" => crawl}} = conn |> get(~p"/api/stats") |> json_response(200)

      assert %{"candidates" => 0, "links_read" => 0, "fetched" => 1, "stored_bytes" => 500} =
               crawl
    end
  end
end
