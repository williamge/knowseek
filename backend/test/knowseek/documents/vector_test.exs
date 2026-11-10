defmodule Knowseek.Documents.VectorTest do
  use ExUnit.Case, async: true

  alias Knowseek.Documents.Vector

  test "encodes float32 little-endian and decodes back" do
    blob = Vector.encode([1.0, -2.5, 0])

    assert blob == <<1.0::float-32-little, -2.5::float-32-little, 0.0::float-32-little>>
    assert Vector.decode(blob) == [1.0, -2.5, 0.0]
  end

  test "dumps a list to a binary and loads it back as an Ecto type" do
    assert {:ok, blob} = Ecto.Type.dump(Vector, [0.5, 0.25])
    assert {:ok, [0.5, 0.25]} = Ecto.Type.load(Vector, blob)
    assert Vector.type() == :binary
  end

  test "rejects values that are not vectors" do
    assert :error = Ecto.Type.cast(Vector, "[1, 2]")
    assert :error = Ecto.Type.dump(Vector, "[1, 2]")
  end

  test "rounds to float32, as the index stores it" do
    [x] = [0.1] |> Vector.encode() |> Vector.decode()
    assert x != 0.1
    assert_in_delta x, 0.1, 1.0e-7
  end
end
