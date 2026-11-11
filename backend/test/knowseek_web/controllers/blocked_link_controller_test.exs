defmodule KnowseekWeb.BlockedLinkControllerTest do
  use KnowseekWeb.ConnCase, async: false

  alias Knowseek.Discovery
  alias Knowseek.Discovery.LinkBackfillWorker

  setup do
    config = Application.fetch_env!(:knowseek, Discovery)
    on_exit(fn -> Application.put_env(:knowseek, Discovery, config) end)

    Application.put_env(
      :knowseek,
      Discovery,
      Keyword.put(config, :sources, [Discovery.LinkSource])
    )
  end

  describe "GET /api/blocked-links" do
    test "returns the log by domain, with the allowed hosts from config", %{conn: conn} do
      one = document_fixture()
      two = document_fixture()
      {:ok, 2} = Discovery.record_links(one.id, ["https://a.example/1", "https://a.example/2"])
      {:ok, 1} = Discovery.record_links(two.id, ["https://a.example/1"])

      assert %{
               "data" => %{
                 "allowed_hosts" => ["en.wikipedia.org", "en.wikibooks.org"],
                 "total_domains" => 1,
                 "total_links" => 2,
                 "domains" => [
                   %{
                     "host" => "a.example",
                     "links" => 2,
                     "pages" => 2,
                     "times_seen" => 3,
                     "first_seen_at" => first_seen_at,
                     "example_url" => "https://a.example/1"
                   }
                 ]
               }
             } = conn |> get(~p"/api/blocked-links") |> json_response(200)

      assert {:ok, _time, 0} = DateTime.from_iso8601(first_seen_at)
    end

    test "an empty log", %{conn: conn} do
      assert %{
               "data" => %{
                 "allowed_hosts" => ["en.wikipedia.org", "en.wikibooks.org"],
                 "total_domains" => 0,
                 "total_links" => 0,
                 "domains" => []
               }
             } = conn |> get(~p"/api/blocked-links") |> json_response(200)
    end
  end

  describe "POST /api/blocked-links/backfill" do
    test "answers 202 with the number of documents and enqueues the jobs", %{conn: conn} do
      {:ok, _summary} = Discovery.run("tide pools", sources: [Discovery.LinkSource])
      [%{id: id}] = Knowseek.Documents.list_documents()

      assert %{"data" => %{"enqueued" => 1}} =
               conn |> post(~p"/api/blocked-links/backfill") |> json_response(202)

      assert_enqueued(worker: LinkBackfillWorker, args: %{"document_id" => id})
    end

    test "is 202 with zero when nothing is indexed", %{conn: conn} do
      assert %{"data" => %{"enqueued" => 0}} =
               conn |> post(~p"/api/blocked-links/backfill") |> json_response(202)
    end
  end
end
