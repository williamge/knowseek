defmodule Knowseek.RepoTest do
  use Knowseek.DataCase, async: false

  alias Knowseek.Documents.Vector
  alias Mix.Tasks.SqliteVec.Fetch

  test "every connection loads the pinned sqlite-vec" do
    assert %{rows: [["v0.1.9"]]} = Repo.query!("SELECT vec_version()")
  end

  test "sqlite-vec reads a vector bound as a blob, and rejects one bound as text" do
    a = Vector.encode([1.0, 0.0])
    b = Vector.encode([0.0, 1.0])

    assert %{rows: [[distance]]} =
             Repo.query!("SELECT vec_distance_cosine(?1, ?2)", [{:blob, a}, {:blob, b}])

    assert_in_delta distance, 1.0, 1.0e-6

    # An Elixir binary is bound as TEXT, which sqlite-vec parses as JSON.
    assert_raise Exqlite.Error, fn -> Repo.query!("SELECT vec_length(?1)", [a]) end
  end

  test "mix sqlite_vec.fetch does nothing when the pinned build is in place" do
    assert File.exists?(Repo.sqlite_vec() <> ext())
    assert Fetch.run([]) == :ok
  end

  defp ext, do: if(match?({:unix, :darwin}, :os.type()), do: ".dylib", else: ".so")
end
