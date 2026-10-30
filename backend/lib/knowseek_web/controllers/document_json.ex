defmodule KnowseekWeb.DocumentJSON do
  alias Knowseek.Documents.Document

  def index(%{documents: documents}), do: %{data: Enum.map(documents, &data/1)}

  def show(%{document: document}), do: %{data: data(document)}

  defp data(%Document{} = document) do
    %{
      id: document.id,
      url: document.url,
      title: document.title,
      body: document.body,
      source: document.source,
      published_at: document.published_at,
      fetched_at: document.fetched_at,
      metadata: document.metadata
    }
  end
end
