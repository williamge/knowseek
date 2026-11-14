defmodule Knowseek.EmbeddingsTest do
  # Changes global application config.
  use ExUnit.Case, async: false

  alias Knowseek.Embeddings

  test "returns one vector per text" do
    assert {:ok, [a, b]} = Embeddings.embed(["one", "two"])
    assert length(a) == Embeddings.dimensions()
    assert length(b) == Embeddings.dimensions()
  end

  test "rejects an adapter result with the wrong number of vectors" do
    config = Application.fetch_env!(:knowseek, Embeddings)
    on_exit(fn -> Application.put_env(:knowseek, Embeddings, config) end)

    Application.put_env(
      :knowseek,
      Embeddings,
      Keyword.put(config, :adapter, Knowseek.Embeddings.ShortAdapter)
    )

    assert {:error, {:vector_count_mismatch, _}} = Embeddings.embed(["one", "two"])
  end

  test "rejects an unknown input type instead of passing it to the adapter" do
    assert {:error, {:invalid_input_type, "query"}} =
             Embeddings.embed(["one"], input_type: "query")

    assert {:error, {:invalid_input_type, nil}} = Embeddings.embed([], input_type: nil)
  end

  describe "model/0 and refresh_model/0" do
    setup do
      config = Application.fetch_env!(:knowseek, Embeddings)

      on_exit(fn ->
        Application.put_env(:knowseek, Embeddings, config)
        Application.delete_env(:knowseek, Knowseek.Embeddings.Hashing)
        Embeddings.refresh_model()
      end)

      {:ok, _} = Embeddings.refresh_model()
      %{config: config}
    end

    test "returns the name, the digest and the dimensions" do
      assert {:ok, %{name: "hashing/1", digest: "", dimensions: dimensions}} = Embeddings.model()
      assert dimensions == Embeddings.dimensions()
    end

    test "asks the adapter once, then answers from memory" do
      Application.put_env(:knowseek, Knowseek.Embeddings.Hashing, version: 2)

      assert {:ok, %{name: "hashing/1"}} = Embeddings.model()
      assert {:ok, %{name: "hashing/2"}} = Embeddings.refresh_model()
      assert {:ok, %{name: "hashing/2"}} = Embeddings.model()
    end

    test "asks the new adapter after the configured adapter changed", %{config: config} do
      assert {:ok, %{name: "hashing/1"}} = Embeddings.model()

      Application.put_env(
        :knowseek,
        Embeddings,
        Keyword.put(config, :adapter, Knowseek.Embeddings.ShortAdapter)
      )

      assert {:ok, %{name: "short/1", digest: ""}} = Embeddings.model()
    end

    test "leaves what was remembered when the adapter fails", %{config: config} do
      assert {:ok, %{name: "hashing/1"} = remembered} = Embeddings.model()

      Req.Test.stub(Knowseek.Embeddings.Ollama, &Req.Test.transport_error(&1, :econnrefused))

      Application.put_env(
        :knowseek,
        Embeddings,
        Keyword.put(config, :adapter, Knowseek.Embeddings.Ollama)
      )

      assert {:error, {:ollama, %Req.TransportError{}}} = Embeddings.model()
      assert {:error, {:ollama, %Req.TransportError{}}} = Embeddings.refresh_model()

      Application.put_env(:knowseek, Embeddings, config)
      assert {:ok, ^remembered} = Embeddings.model()

      assert {Knowseek.Embeddings.Hashing, ^remembered} =
               :persistent_term.get({Embeddings, :model})
    end
  end

  describe "embed_batches/2" do
    test "concatenates the vectors of each batch in order" do
      batches = [["a", "b"], ["c"]]
      fun = fn batch -> {:ok, Enum.map(batch, &[byte_size(&1) * 1.0])} end

      assert {:ok, [[1.0], [1.0], [1.0]]} = Embeddings.embed_batches(batches, fun)
    end

    test "stops at the first error" do
      test_pid = self()

      fun = fn
        ["bad"] ->
          {:error, :boom}

        batch ->
          send(test_pid, {:called, batch})
          {:ok, [[1.0]]}
      end

      assert {:error, :boom} = Embeddings.embed_batches([["ok"], ["bad"], ["later"]], fun)
      assert_received {:called, ["ok"]}
      refute_received {:called, ["later"]}
    end

    test "returns no vectors for no batches" do
      assert {:ok, []} = Embeddings.embed_batches([], fn _ -> flunk("not called") end)
    end
  end
end
