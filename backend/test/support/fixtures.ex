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

  def topic_fixture(attrs \\ %{}) do
    {:ok, topic, :created} =
      attrs
      |> Enum.into(%{query: "elixir releases"})
      |> Knowseek.Topics.follow_topic()

    topic
  end
end
