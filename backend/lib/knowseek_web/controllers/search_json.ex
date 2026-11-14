defmodule KnowseekWeb.SearchJSON do
  alias Knowseek.Search.Hit
  alias KnowseekWeb.DocumentJSON

  def show(%{result: result}) do
    %{
      data: %{
        query: result.query,
        coverage: result.coverage,
        discovery: discovery(result.discovery),
        hits: Enum.map(result.hits, &hit/1)
      }
    }
  end

  defp discovery(:not_needed), do: %{status: "not_needed"}
  defp discovery({:enqueued, job_id}), do: %{status: "enqueued", job_id: job_id}
  defp discovery({:refused, reason}), do: %{status: "refused", reason: reason}
  defp discovery({:error, reason}), do: %{status: "error", reason: inspect(reason)}

  defp hit(%Hit{} = hit) do
    %{
      document_id: hit.document_id,
      chunk_id: hit.chunk_id,
      url: hit.url,
      title: hit.title,
      content: hit.content,
      published_at: hit.published_at,
      fetched_at: hit.fetched_at,
      source_updated_at: hit.source_updated_at,
      license: hit.license,
      attribution: DocumentJSON.attribution(hit.attribution),
      modified: hit.modified,
      share: hit.share,
      score: hit.score,
      keyword_rank: hit.keyword_rank,
      semantic_rank: hit.semantic_rank,
      similarity: hit.similarity,
      passages: Enum.map(hit.passages, &passage/1)
    }
  end

  defp passage(passage), do: Map.take(passage, [:chunk_id, :content, :score])
end
