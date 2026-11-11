defmodule KnowseekWeb.StatsControllerTest do
  use KnowseekWeb.ConnCase, async: false

  alias Knowseek.Activity

  @keys ~w(searches pages disk_bytes network hit_share)

  describe "GET /api/stats" do
    test "has the documented shape on an empty database", %{conn: conn} do
      assert %{"data" => data} = conn |> get(~p"/api/stats") |> json_response(200)

      assert Enum.sort(Map.keys(data)) == Enum.sort(@keys)
      assert data["searches"] == %{"total" => 0, "days" => []}
      assert data["pages"] == %{"search" => 0, "background" => 0, "manual" => 0}
      assert data["network"] == []
      assert data["hit_share"] == %{"background_pages" => 0, "hit_pages" => 0}
      assert data["disk_bytes"] > 0
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
  end
end
