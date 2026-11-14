defmodule Knowseek.Embeddings.OllamaTest do
  # Changes global application config.
  use Knowseek.DataCase, async: false

  alias Knowseek.{Documents, Embeddings, Search}
  alias Knowseek.Documents.EmbeddingModel
  alias Knowseek.Embeddings.Ollama

  @digest "7907646426070047a77226ac3e684fbbe8410524f7b4a74d02837e43f2146bab"

  @opts [dimensions: 4, input_type: :document]

  setup do
    config = Application.fetch_env!(:knowseek, Ollama)
    on_exit(fn -> Application.put_env(:knowseek, Ollama, config) end)
    %{config: config}
  end

  describe "embed/2" do
    test "sends the texts and model, and returns the vectors" do
      test_pid = self()

      Req.Test.stub(Ollama, fn conn ->
        body = decode_body(conn)
        send(test_pid, {:request, conn.request_path, body})
        respond(conn, body, 4)
      end)

      assert {:ok, [a, b]} = Ollama.embed(["one", "two"], @opts)
      assert a == vector(0, 4)
      assert b == vector(1, 4)

      assert_received {:request, "/api/embed", body}

      assert body == %{
               "model" => "bge-m3",
               "input" => ["one", "two"],
               "truncate" => true,
               "keep_alive" => "24h"
             }
    end

    test "splits texts into batches and keeps the order", %{config: config} do
      Application.put_env(:knowseek, Ollama, Keyword.put(config, :max_batch_size, 2))
      test_pid = self()

      Req.Test.stub(Ollama, fn conn ->
        body = decode_body(conn)
        send(test_pid, {:batch, body["input"]})
        embeddings = Enum.map(body["input"], &[String.to_integer(&1) * 1.0])
        Req.Test.json(conn, %{"embeddings" => embeddings})
      end)

      assert {:ok, [[1.0], [2.0], [3.0]]} = Ollama.embed(["1", "2", "3"], @opts)
      assert_received {:batch, ["1", "2"]}
      assert_received {:batch, ["3"]}
    end

    test "retries on 5xx, then succeeds" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Ollama, fn conn ->
        case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
          0 -> conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "loading"})
          _ -> respond(conn, decode_body(conn), 4)
        end
      end)

      assert {:ok, [_]} = Ollama.embed(["one"], @opts)
      assert Agent.get(attempts, & &1) == 2
    end

    test "does not retry a :query call" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Ollama, fn conn ->
        Agent.update(attempts, &(&1 + 1))
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "loading"})
      end)

      assert {:error, {:ollama, 503, "loading"}} =
               Ollama.embed(["one"], dimensions: 4, input_type: :query)

      assert Agent.get(attempts, & &1) == 1
    end

    test "returns an error when the model is not pulled" do
      Req.Test.stub(Ollama, fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => ~s(model "bge-m3" not found, try pulling it first)})
      end)

      assert {:error, {:ollama, 404, "model \"bge-m3\" not found" <> _}} =
               Ollama.embed(["one"], @opts)
    end

    test "returns an error when the server is not running" do
      Req.Test.stub(Ollama, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:ollama, %Req.TransportError{reason: :econnrefused}}} =
               Ollama.embed(["one"], @opts)
    end

    test "returns an error when the response has the wrong number of vectors" do
      Req.Test.stub(Ollama, &Req.Test.json(&1, %{"embeddings" => [[1.0]]}))
      assert {:error, {:ollama, :unexpected_response}} = Ollama.embed(["a", "b"], @opts)
    end
  end

  describe "model/0" do
    test "sends GET /api/tags and finds bge-m3 as bge-m3:latest" do
      test_pid = self()

      Req.Test.stub(Ollama, fn conn ->
        send(test_pid, {:request, conn.method, conn.request_path})
        Req.Test.json(conn, tags(["nomic-embed-text:latest", "bge-m3:latest"]))
      end)

      assert {:ok, %{name: "ollama/bge-m3:latest", digest: @digest}} = Ollama.model()
      assert_received {:request, "GET", "/api/tags"}
    end

    test "finds an exact name:tag", %{config: config} do
      Application.put_env(:knowseek, Ollama, Keyword.put(config, :model, "bge-m3:567m"))
      Req.Test.stub(Ollama, &Req.Test.json(&1, tags(["bge-m3:latest", "bge-m3:567m"])))

      assert {:ok, %{name: "ollama/bge-m3:567m", digest: @digest}} = Ollama.model()
    end

    test "returns :model_not_found when the list lacks the model" do
      Req.Test.stub(Ollama, &Req.Test.json(&1, tags(["nomic-embed-text:latest"])))
      assert {:error, {:ollama, :model_not_found}} = Ollama.model()
    end

    test "returns :unexpected_response for a body without a model list" do
      Req.Test.stub(Ollama, &Req.Test.json(&1, %{"nope" => []}))
      assert {:error, {:ollama, :unexpected_response}} = Ollama.model()
    end

    test "returns a transport error in the adapter's shape" do
      Req.Test.stub(Ollama, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, {:ollama, %Req.TransportError{reason: :econnrefused}}} = Ollama.model()
    end

    test "returns a 500 in the adapter's shape, without a retry" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Ollama, fn conn ->
        Agent.update(attempts, &(&1 + 1))
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      assert {:error, {:ollama, 500, "boom"}} = Ollama.model()
      assert Agent.get(attempts, & &1) == 1
    end
  end

  describe "as the configured adapter" do
    setup do
      config = Application.fetch_env!(:knowseek, Embeddings)
      on_exit(fn -> Application.put_env(:knowseek, Embeddings, config) end)
      Application.put_env(:knowseek, Embeddings, Keyword.put(config, :adapter, Ollama))
    end

    test "Documents.ingest/1 stores Ollama vectors" do
      dimensions = Embeddings.dimensions()
      stub_server(dimensions)

      assert {:ok, document} = Documents.ingest(%{body: "Some text.", source: "test"})
      assert [chunk] = Repo.preload(document, :chunks).chunks
      assert chunk_embedding(chunk) == vector(0, dimensions)
      assert [model_id] = vector_model_ids(document)
      assert document.embedding_model_id == model_id

      assert %{name: "ollama/bge-m3:latest", digest: @digest} =
               Repo.get!(EmbeddingModel, model_id)
    end

    test "rejects a model with the wrong vector size" do
      stub_server(768)

      assert {:error, {:dimension_mismatch, expected: 1024}} =
               Documents.ingest(%{body: "Some text.", source: "test"})
    end

    test "Documents.ingest/1 and Search.search/2 return an error when Ollama fails" do
      Req.Test.stub(Ollama, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:ollama, %Req.TransportError{}}} =
               Documents.ingest(%{body: "Some text.", source: "test"})

      assert {:error, {:ollama, %Req.TransportError{}}} = Search.search("anything")
    end
  end

  # Answers `GET /api/tags` and `POST /api/embed` like a running Ollama.
  defp stub_server(dimensions) do
    Req.Test.stub(Ollama, fn
      %{request_path: "/api/tags"} = conn -> Req.Test.json(conn, tags(["bge-m3:latest"]))
      conn -> respond(conn, decode_body(conn), dimensions)
    end)
  end

  defp tags(names) do
    %{"models" => Enum.map(names, &%{"name" => &1, "model" => &1, "digest" => @digest})}
  end

  defp decode_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end

  # Answers like Ollama: one vector of `dimensions` values per input.
  defp respond(conn, %{"input" => input}, dimensions) do
    embeddings = input |> Enum.with_index() |> Enum.map(fn {_, i} -> vector(i, dimensions) end)
    Req.Test.json(conn, %{"model" => "bge-m3", "embeddings" => embeddings})
  end

  defp vector(i, dimensions) do
    for d <- 0..(dimensions - 1), do: if(d == rem(i, dimensions), do: 1.0, else: 0.0)
  end
end
