defmodule KnowseekWeb.DocumentJSON do
  alias Knowseek.Documents.{Attribution, Document}

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
      license: document.license,
      attribution: attribution(document.attribution),
      modified: document.modified,
      share: document.share,
      metadata: document.metadata
    }
  end

  @doc "`{url, credit, authors}`, or `nil` when the document has no attribution."
  def attribution(nil), do: nil

  def attribution(%Attribution{} = attribution),
    do: Map.take(attribution, [:url, :credit, :authors])
end
