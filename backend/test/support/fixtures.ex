defmodule Knowseek.Fixtures do
  @moduledoc "Test data helpers."

  def document_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, document} =
      attrs
      |> Enum.into(%{
        url: "https://example.com/doc-#{n}",
        title: "Document #{n}",
        body: "Some body text for document #{n}.",
        source: "test"
      })
      |> Knowseek.Documents.ingest()

    document
  end

  @doc """
  A body long enough to be merged by content hash (see
  `Knowseek.Documents.min_alias_body_length/0`). Different `tag`s give
  different bodies.
  """
  def long_body(tag \\ "a") do
    "Article #{tag}. " <>
      String.duplicate("This sentence pads the body past the alias length floor. ", 8)
  end

  def topic_fixture(attrs \\ %{}) do
    {:ok, topic, :created} =
      attrs
      |> Enum.into(%{query: "elixir releases"})
      |> Knowseek.Topics.follow_topic()

    topic
  end
end
