defmodule KnowseekWeb.DocumentJSON do
  alias Knowseek.Documents.Document

  @doc "A list has no bodies. `show/1` returns the full document."
  def index(%{documents: documents}), do: %{data: Enum.map(documents, &summary/1)}

  def show(%{document: document}), do: %{data: Map.put(summary(document), :body, document.body)}

  defp summary(%Document{} = document) do
    %{
      id: document.id,
      url: document.url,
      title: document.title,
      source: document.source,
      published_at: document.published_at,
      fetched_at: document.fetched_at,
      source_updated_at: document.source_updated_at,
      metadata: document.metadata
    }
  end
end
