defmodule KnowseekWeb.CrawlControllerTest do
  use KnowseekWeb.ConnCase, async: false

  alias Knowseek.Crawl.{Candidate, SourcePage}
  alias Knowseek.Repo

  setup do
    original = Application.fetch_env!(:knowseek, Knowseek.Crawl)
    on_exit(fn -> Application.put_env(:knowseek, Knowseek.Crawl, original) end)
    {:ok, original: original}
  end

  defp put_crawl(original, overrides),
    do: Application.put_env(:knowseek, Knowseek.Crawl, Keyword.merge(original, overrides))

  describe "GET /api/crawl" do
    test "has the documented shape on an empty database", %{conn: conn, original: original} do
      put_crawl(original, mode: :preview, bar: 0.4, pages_per_day: 100)

      assert %{"data" => data} = conn |> get(~p"/api/crawl") |> json_response(200)

      assert data == %{
               "mode" => "preview",
               "pages_per_day" => 100,
               "fetched_today" => 0,
               "bar" => 0.4,
               "next" => []
             }
    end

    test "lists a pending candidate of a source page that a search showed", %{
      conn: conn,
      original: original
    } do
      put_crawl(original, mode: :preview, bar: 0.4)

      source = crawl_source_fixture(title: "Sourdough", query: "sourdough starter")
      now = DateTime.utc_now(:second)

      Repo.insert!(%SourcePage{
        document_id: source.id,
        site: "crawl",
        link_ids: [77],
        links: 1,
        kept: 1,
        read_at: now
      })

      Repo.insert!(%Candidate{
        source_document_id: source.id,
        page_id: 77,
        site: "crawl",
        title: "Desem",
        description: "sourdough starter",
        url: "https://en.wikipedia.org/?curid=77",
        interest: 0.91234,
        novelty: 0.8,
        gap: 0.1,
        shared: 0.0,
        shared_count: 1,
        score: 0.82987,
        state: "pending",
        scored_at: now
      })

      assert %{"data" => %{"next" => [entry]} = data} =
               conn |> get(~p"/api/crawl") |> json_response(200)

      assert data["mode"] == "preview"
      assert data["fetched_today"] == 0

      assert entry == %{
               "title" => "Desem",
               "description" => "sourdough starter",
               "url" => "https://en.wikipedia.org/?curid=77",
               "source" => %{
                 "document_id" => source.id,
                 "title" => source.title,
                 "url" => source.url,
                 "queries" => ["sourdough starter"]
               },
               "interest" => 0.912,
               "novelty" => 0.8,
               "gap" => 0.1,
               "shared" => 0.0,
               "shared_count" => 1,
               "score" => 0.83
             }
    end

    test "leaves out a candidate under the bar", %{conn: conn, original: original} do
      put_crawl(original, mode: :preview, bar: 0.9)

      source = crawl_source_fixture(query: "sourdough starter")
      now = DateTime.utc_now(:second)

      Repo.insert!(%Candidate{
        source_document_id: source.id,
        page_id: 78,
        site: "crawl",
        title: "Weak",
        url: "https://en.wikipedia.org/?curid=78",
        interest: 0.5,
        novelty: 0.5,
        score: 0.25,
        scored_at: now
      })

      assert %{"data" => %{"next" => []}} = conn |> get(~p"/api/crawl") |> json_response(200)
    end
  end
end
