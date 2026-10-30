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
    test "create, list, delete", %{conn: conn} do
      %{"data" => %{"id" => id}} =
        conn |> post(~p"/api/topics", topic: %{query: "fusion energy"}) |> json_response(201)

      assert %{"data" => [%{"id" => ^id}]} = conn |> get(~p"/api/topics") |> json_response(200)
      assert conn |> delete(~p"/api/topics/#{id}") |> response(204)
      assert %{"data" => []} = conn |> get(~p"/api/topics") |> json_response(200)
    end
  end
end
