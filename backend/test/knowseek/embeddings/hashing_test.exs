defmodule Knowseek.Embeddings.HashingTest do
  # `model/0` tests change global application config.
  use ExUnit.Case, async: false

  alias Knowseek.Embeddings.Hashing

  @opts [dimensions: 64]

  test "returns unit-length vectors of the configured size" do
    {:ok, [vector]} = Hashing.embed(["hello world"], @opts)

    assert length(vector) == 64
    assert_in_delta norm(vector), 1.0, 1.0e-9
  end

  describe "model/0" do
    setup do
      on_exit(fn -> Application.delete_env(:knowseek, Hashing) end)
    end

    test "is hashing/1 by default, with no digest" do
      assert {:ok, %{name: "hashing/1", digest: ""}} = Hashing.model()
    end

    test "takes the version from the config" do
      Application.put_env(:knowseek, Hashing, version: 2)
      assert {:ok, %{name: "hashing/2", digest: ""}} = Hashing.model()
    end
  end

  test "is deterministic" do
    assert Hashing.embed(["same text"], @opts) == Hashing.embed(["same text"], @opts)
  end

  test "gives texts with shared words a higher similarity" do
    {:ok, [a, b, c]} =
      Hashing.embed(
        ["postgres vector search", "vector search in postgres", "baking bread"],
        @opts
      )

    assert dot(a, b) > dot(a, c)
  end

  test "returns a non-zero vector for text without tokens" do
    {:ok, [vector]} = Hashing.embed(["!!!"], @opts)
    assert_in_delta norm(vector), 1.0, 1.0e-9
  end

  defp dot(a, b), do: Enum.zip_with(a, b, &(&1 * &2)) |> Enum.sum()
  defp norm(v), do: :math.sqrt(dot(v, v))
end
