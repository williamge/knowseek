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
end
