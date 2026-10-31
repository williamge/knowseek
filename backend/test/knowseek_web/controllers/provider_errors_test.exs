defmodule KnowseekWeb.ProviderErrorsTest do
  # Switches the global embedding adapter to Ollama, with Req.Test stubs.
  use KnowseekWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Knowseek.Embeddings.Ollama

  setup do
    config = Application.fetch_env!(:knowseek, Knowseek.Embeddings)
    Application.put_env(:knowseek, Knowseek.Embeddings, Keyword.put(config, :adapter, Ollama))
    on_exit(fn -> Application.put_env(:knowseek, Knowseek.Embeddings, config) end)
    :ok
  end

  @detail %{"errors" => %{"detail" => "Embedding provider unavailable (ollama)"}}

  describe "transport error (Ollama not running)" do
    setup do
      Req.Test.stub(Ollama, &Req.Test.transport_error(&1, :econnrefused))
    end

    test "POST /api/search is a 503", %{conn: conn} do
      capture_log(fn ->
        assert @detail == conn |> post(~p"/api/search", query: "cats") |> json_response(503)
      end)
    end

    test "POST /api/documents is a 503", %{conn: conn} do
      capture_log(fn ->
        params = %{document: %{title: "Cats", body: "Cats purr."}}
        assert @detail == conn |> post(~p"/api/documents", params) |> json_response(503)
      end)
    end
  end

  describe "HTTP error status (model not pulled)" do
    setup do
      Req.Test.stub(Ollama, fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => "model \"bge-m3\" not found, try pulling it first"})
      end)
    end

    test "POST /api/search is a 503", %{conn: conn} do
      capture_log(fn ->
        assert @detail == conn |> post(~p"/api/search", query: "cats") |> json_response(503)
      end)
    end

    test "POST /api/documents is a 503", %{conn: conn} do
      capture_log(fn ->
        params = %{document: %{title: "Cats", body: "Cats purr."}}
        assert @detail == conn |> post(~p"/api/documents", params) |> json_response(503)
      end)
    end
  end
end
