defmodule Knowseek.Embeddings.VoyageTest do
  # Changes global application config.
  use Knowseek.DataCase, async: false

  alias Knowseek.{Documents, Embeddings, Search}
  alias Knowseek.Embeddings.Voyage

  @opts [dimensions: 4, input_type: :document]

  setup do
    config = Application.fetch_env!(:knowseek, Voyage)
    on_exit(fn -> Application.put_env(:knowseek, Voyage, config) end)
    %{config: config}
  end

  describe "embed/2" do
    test "sends the texts, model, input type, and size, and returns the vectors" do
      test_pid = self()

      Req.Test.stub(Voyage, fn conn ->
        body = decode_body(conn)
        send(test_pid, {:request, conn.req_headers, body})
        respond(conn, body)
      end)

      assert {:ok, [a, b]} = Voyage.embed(["one", "two"], dimensions: 4, input_type: :query)
      assert a == vector(0, 4)
      assert b == vector(1, 4)

      assert_received {:request, headers, body}
      assert {"authorization", "Bearer test-key"} in headers

      assert body == %{
               "input" => ["one", "two"],
               "model" => "voyage-3.5",
               "input_type" => "query",
               "output_dimension" => 4
             }
    end

    test "orders vectors by the index field, not by response order" do
      Req.Test.stub(Voyage, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{"index" => 1, "embedding" => [2.0]},
            %{"index" => 0, "embedding" => [1.0]}
          ]
        })
      end)

      assert {:ok, [[1.0], [2.0]]} = Voyage.embed(["a", "b"], @opts)
    end

    test "splits texts into batches and keeps the order", %{config: config} do
      Application.put_env(:knowseek, Voyage, Keyword.put(config, :max_batch_size, 2))
      test_pid = self()

      Req.Test.stub(Voyage, fn conn ->
        body = decode_body(conn)
        send(test_pid, {:batch, body["input"]})

        data =
          for {text, i} <- Enum.with_index(body["input"]),
              do: %{"index" => i, "embedding" => [String.to_integer(text) * 1.0]}

        Req.Test.json(conn, %{"data" => data})
      end)

      assert {:ok, [[1.0], [2.0], [3.0]]} = Voyage.embed(["1", "2", "3"], @opts)
      assert_received {:batch, ["1", "2"]}
      assert_received {:batch, ["3"]}
    end

    test "retries on 429 and 5xx, then succeeds" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Voyage, fn conn ->
        case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
          0 -> conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"detail" => "slow down"})
          1 -> conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"detail" => "unavailable"})
          _ -> respond(conn, decode_body(conn))
        end
      end)

      assert {:ok, [_]} = Voyage.embed(["one"], @opts)
      assert Agent.get(attempts, & &1) == 3
    end

    test "returns an error when retries run out" do
      Req.Test.stub(Voyage, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"detail" => "boom"})
      end)

      assert {:error, {:voyage, 500, "boom"}} = Voyage.embed(["one"], @opts)
    end

    test "does not retry a client error" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Voyage, fn conn ->
        Agent.update(attempts, &(&1 + 1))
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"detail" => "bad key"})
      end)

      assert {:error, {:voyage, 401, "bad key"}} = Voyage.embed(["one"], @opts)
      assert Agent.get(attempts, & &1) == 1
    end

    test "returns an error on a transport error" do
      Req.Test.stub(Voyage, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:voyage, %Req.TransportError{reason: :econnrefused}}} =
               Voyage.embed(["one"], @opts)
    end

    test "returns an error when the response has the wrong number of vectors" do
      Req.Test.stub(Voyage, fn conn ->
        Req.Test.json(conn, %{"data" => [%{"index" => 0, "embedding" => [1.0]}]})
      end)

      assert {:error, {:voyage, :unexpected_response}} = Voyage.embed(["a", "b"], @opts)
    end

    test "returns an error when no API key is configured", %{config: config} do
      Application.put_env(:knowseek, Voyage, Keyword.delete(config, :api_key))
      assert {:error, {:voyage, :missing_api_key}} = Voyage.embed(["one"], @opts)
    end
  end

  describe "batches/2" do
    test "respects the batch size" do
      assert Voyage.batches(~w(a b c d e), max_batch_size: 2) == [~w(a b), ~w(c d), ~w(e)]
    end

    test "respects the estimated token limit" do
      long = String.duplicate("x", 30)
      # Each text is estimated at 11 tokens.
      assert Voyage.batches([long, long, long], max_batch_tokens: 25) ==
               [[long, long], [long]]
    end

    test "puts a text over the token limit in its own batch" do
      long = String.duplicate("x", 300)
      assert Voyage.batches(["a", long, "b"], max_batch_tokens: 10) == [["a"], [long], ["b"]]
    end

    test "returns no batches for no texts" do
      assert Voyage.batches([], []) == []
    end
  end

  describe "as the configured adapter" do
    setup do
      config = Application.fetch_env!(:knowseek, Embeddings)
      on_exit(fn -> Application.put_env(:knowseek, Embeddings, config) end)
      Application.put_env(:knowseek, Embeddings, Keyword.put(config, :adapter, Voyage))
    end

    test "Documents.ingest/1 stores Voyage vectors for document input" do
      test_pid = self()

      Req.Test.stub(Voyage, fn conn ->
        body = decode_body(conn)
        send(test_pid, {:input_type, body["input_type"]})
        respond(conn, body)
      end)

      assert {:ok, document} = Documents.ingest(%{body: "Some text.", source: "test"})
      assert [chunk] = Repo.preload(document, :chunks).chunks
      assert Pgvector.to_list(chunk.embedding) == vector(0, Embeddings.dimensions())
      assert_received {:input_type, "document"}
    end

    test "Search.search/2 sends the query as a query" do
      test_pid = self()

      Req.Test.stub(Voyage, fn conn ->
        body = decode_body(conn)
        send(test_pid, {:input_type, body["input_type"]})
        respond(conn, body)
      end)

      assert {:ok, %{hits: []}} = Search.search("anything")
      assert_received {:input_type, "query"}
    end

    test "Documents.ingest/1 returns an error when the provider fails" do
      Req.Test.stub(Voyage, &Req.Test.transport_error(&1, :timeout))

      assert {:error, {:voyage, %Req.TransportError{}}} =
               Documents.ingest(%{body: "Some text.", source: "test"})

      assert Documents.list_documents() == []
    end

    test "Search.search/2 returns an error when the provider fails" do
      Req.Test.stub(Voyage, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"detail" => "boom"})
      end)

      assert {:error, {:voyage, 500, "boom"}} = Search.search("anything")
    end
  end

  defp decode_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end

  # Answers like the API: one vector of the requested size per input.
  defp respond(conn, %{"input" => input, "output_dimension" => dimensions}) do
    data =
      input
      |> Enum.with_index()
      |> Enum.map(fn {_text, i} -> %{"index" => i, "embedding" => vector(i, dimensions)} end)

    Req.Test.json(conn, %{"data" => data, "model" => "voyage-3.5"})
  end

  defp vector(i, dimensions) do
    for d <- 0..(dimensions - 1), do: if(d == rem(i, dimensions), do: 1.0, else: 0.0)
  end
end
