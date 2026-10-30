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
