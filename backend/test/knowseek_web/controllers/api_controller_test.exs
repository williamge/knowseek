defmodule KnowseekWeb.ApiControllerTest do
  use KnowseekWeb.ConnCase, async: true

  alias Knowseek.Discovery.SeekWorker

  test "GET /api/health", %{conn: conn} do
    assert %{"status" => "ok", "database" => "ok"} =
             conn |> get(~p"/api/health") |> json_response(200)
  end

  describe "POST /api/search" do
    test "returns hits and coverage", %{conn: conn} do
      document = document_fixture(title: "Kelp", body: "Kelp forests grow along cold coasts.")

      data =
        conn
        |> post(~p"/api/search", query: "kelp forests")
        |> json_response(200)
        |> Map.fetch!("data")

      assert %{"query" => "kelp forests", "coverage" => "partial", "hits" => [hit]} = data
      assert %{"status" => "enqueued", "job_id" => _} = data["discovery"]
      assert hit["document_id"] == document.id
      assert hit["title"] == "Kelp"
      assert_enqueued(worker: SeekWorker)
    end

    test "accepts max_age_seconds", %{conn: conn} do
      old = ~U[2020-01-01 00:00:00Z]

      document_fixture(
        body: "Glaciers retreat in warm summers.",
        published_at: old,
        fetched_at: old
      )

      data =
        conn
        |> post(~p"/api/search", query: "glaciers retreat", max_age_seconds: 3600)
        |> json_response(200)
        |> Map.fetch!("data")

      assert %{"coverage" => "none", "hits" => [hit]} = data
      assert hit["published_at"] == "2020-01-01T00:00:00Z"
    end

    test "accepts a null max_age_seconds", %{conn: conn} do
      assert %{"data" => _} =
               conn
               |> post(~p"/api/search", %{query: "x", max_age_seconds: nil})
               |> json_response(200)
    end

    test "rejects an invalid max_age_seconds", %{conn: conn} do
      for value <- [0, -5, 3_000_000_000, "1h"] do
        assert %{"errors" => %{"detail" => "max_age_seconds" <> _}} =
                 conn
                 |> post(~p"/api/search", query: "x", max_age_seconds: value)
                 |> json_response(400)
      end
    end

    test "rejects a missing query", %{conn: conn} do
      assert %{"errors" => _} = conn |> post(~p"/api/search", %{}) |> json_response(400)
    end

    test "rejects a blank query", %{conn: conn} do
      assert %{"errors" => _} = conn |> post(~p"/api/search", query: "   ") |> json_response(400)
      refute_enqueued(worker: SeekWorker)
    end

    test "rejects an invalid limit", %{conn: conn} do
      assert %{"errors" => _} =
               conn |> post(~p"/api/search", query: "x", limit: 500) |> json_response(400)
    end
  end

  describe "documents" do
    test "POST then GET a manual document", %{conn: conn} do
      created =
        conn
        |> post(~p"/api/documents", document: %{title: "Note", body: "A manual note."})
        |> json_response(201)
        |> Map.fetch!("data")

      assert created["source"] == "manual"

      assert %{"data" => %{"id" => id}} =
               conn |> get(~p"/api/documents/#{created["id"]}") |> json_response(200)

      assert id == created["id"]
    end

    test "GET /documents lists documents without their bodies", %{conn: conn} do
      document_fixture(title: "Listed", body: "A long body that a list does not need.")

      assert %{"data" => [listed]} = conn |> get(~p"/api/documents") |> json_response(200)

      assert listed["title"] == "Listed"
      refute Map.has_key?(listed, "body")

      assert %{"data" => %{"body" => "A long body that a list does not need."}} =
               conn |> get(~p"/api/documents/#{listed["id"]}") |> json_response(200)
    end

    test "POST returns 422 for an invalid document", %{conn: conn} do
      assert %{"errors" => %{"body" => _}} =
               conn
               |> post(~p"/api/documents", document: %{title: "No body"})
               |> json_response(422)
    end

    test "GET returns 404 for an unknown document", %{conn: conn} do
      conn |> get(~p"/api/documents/#{Ecto.UUID.generate()}") |> json_response(404)
    end
  end

  describe "topics" do
    test "create with max_age_seconds", %{conn: conn} do
      assert %{"data" => %{"max_age_seconds" => 3600}} =
               conn
               |> post(~p"/api/topics", topic: %{query: "fusion energy", max_age_seconds: 3600})
               |> json_response(201)
    end

    test "rejects a max_age_seconds that does not fit the column", %{conn: conn} do
      assert %{"errors" => %{"max_age_seconds" => _}} =
               conn
               |> post(~p"/api/topics",
                 topic: %{query: "fusion energy", max_age_seconds: 3_000_000_000}
               )
               |> json_response(422)
    end

    test "following an existing query returns the topic with 200, unchanged", %{conn: conn} do
      %{"data" => %{"id" => id} = first} =
        conn
        |> post(~p"/api/topics",
          topic: %{query: "Rust", refresh_interval_seconds: 3600, max_age_seconds: 600}
        )
        |> json_response(201)

      assert %{"data" => ^first} =
               conn
               |> post(~p"/api/topics",
                 topic: %{query: "  rust ", refresh_interval_seconds: 604_800}
               )
               |> json_response(200)

      assert %{"data" => [%{"id" => ^id, "query" => "Rust"}]} =
               conn |> get(~p"/api/topics") |> json_response(200)
    end

    test "invalid settings are rejected even for an existing query", %{conn: conn} do
      conn |> post(~p"/api/topics", topic: %{query: "Rust"}) |> json_response(201)

      assert %{"errors" => %{"refresh_interval_seconds" => _}} =
               conn
               |> post(~p"/api/topics", topic: %{query: "rust", refresh_interval_seconds: 1})
               |> json_response(422)
    end

    test "create, list, delete", %{conn: conn} do
      %{"data" => %{"id" => id}} =
        conn |> post(~p"/api/topics", topic: %{query: "fusion energy"}) |> json_response(201)

      assert %{"data" => [%{"id" => ^id}]} = conn |> get(~p"/api/topics") |> json_response(200)
      assert conn |> delete(~p"/api/topics/#{id}") |> response(204)
      assert %{"data" => []} = conn |> get(~p"/api/topics") |> json_response(200)
    end
  end
end
