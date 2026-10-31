defmodule Knowseek.DocumentsConcurrencyTest do
  # Not async: the tasks share the test's database connection.
  use Knowseek.DataCase, async: false

  alias Knowseek.Documents
  alias Knowseek.Documents.{Document, DocumentAlias}

  test "concurrent ingests of one new alias URL record the alias once" do
    body = long_body("race")
    {:ok, first} = Documents.ingest(%{url: "https://a.example/post", body: body, source: "t"})

    results =
      1..6
      |> Task.async_stream(
        fn _ -> Documents.ingest(%{url: "https://b.example/copy", body: body, source: "t"}) end,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %Document{id: id}} when id == first.id, &1))
    assert Repo.all(from a in DocumentAlias, select: a.url) == ["https://b.example/copy"]
    assert Repo.aggregate(Document, :count) == 1
  end
end
