defmodule Knowseek.Documents.Reembed do
  @moduledoc """
  Embeds again the passages of pages whose vectors come from another model
  than the configured one (#84, #53, ADR 0035). Internal: call
  `Knowseek.Documents.reembed_stale/1`.

  Only the vectors change. `chunks`, `chunks_fts`, chunk ids and positions are
  never touched, and neither is `documents.updated_at`. A vector row is
  deleted and inserted again under the same `rowid` (the partition key cannot
  be updated), row by row: `DELETE ... WHERE rowid IN (...)` scans the table.

  This is a second writer of `chunk_vectors` and of one column of `documents`,
  inside the `Knowseek.Documents` context (rule 2 allows it for vectors only).
  """
  import Ecto.Query

  alias Knowseek.Documents.{Chunk, ChunkVector, Document, Lineage}
  alias Knowseek.Embeddings
  alias Knowseek.Repo

  @type result :: {:ok, %{documents: non_neg_integer(), more?: boolean()}} | {:error, term()}

  @doc """
  Re-embeds up to `:limit` stale pages (default: `documents_per_job` from the
  config) with the current model, in storage order. Stops at the first failed
  embedding.
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    limit = Keyword.get_lazy(opts, :limit, fn -> config(:documents_per_job) end)

    with {:ok, model} <- Embeddings.model() do
      ids = model |> Lineage.model_id() |> Lineage.stale_document_ids(limit)

      case reembed_documents(ids, model) do
        {:ok, count} -> {:ok, %{documents: count, more?: finish(model)}}
        {:error, _} = error -> error
      end
    end
  end

  defp reembed_documents(ids, model) do
    Enum.reduce_while(ids, {:ok, 0}, fn id, {:ok, count} ->
      case reembed_document(id, model) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp reembed_document(document_id, model) do
    passages = passages(document_id)
    contents = Enum.map(passages, &elem(&1, 1))

    with {:ok, vectors} <- embed(contents),
         {:ok, _} <- Repo.transact(fn -> {:ok, write(document_id, model, passages, vectors)} end) do
      :ok
    end
  end

  # `[{seq, content}]` in the page's order.
  defp passages(document_id) do
    Repo.all(
      from c in Chunk,
        where: c.document_id == ^document_id,
        order_by: [asc: c.position],
        select: {c.seq, c.content}
    )
  end

  defp embed(contents) do
    contents
    |> Enum.chunk_every(config(:batch_size))
    |> Embeddings.embed_batches(&Embeddings.embed(&1, input_type: :document))
  end

  # A concurrent ingest may have replaced the passages since they were read.
  # It stamped the page itself: write nothing.
  defp write(document_id, model, passages, vectors) do
    seqs = Enum.map(passages, &elem(&1, 0))

    if Enum.map(passages(document_id), &elem(&1, 0)) == seqs do
      model_id = Lineage.ensure_model!(model)

      Enum.each(seqs, &Repo.query!("DELETE FROM chunk_vectors WHERE rowid = ?1", [&1]))

      rows =
        Enum.zip_with(seqs, vectors, fn seq, vector ->
          %{rowid: seq, embedding_model_id: model_id, embedding: vector}
        end)

      if rows != [], do: Repo.insert_all(ChunkVector, rows)

      # `update_all`, so `updated_at` does not move.
      Repo.update_all(from(d in Document, where: d.id == ^document_id),
        set: [embedding_model_id: model_id]
      )
    end

    :ok
  end

  # Whether pages are left. When none is, the model rows no page uses go.
  defp finish(model) do
    model_id = Lineage.model_id(model)
    more? = Lineage.stale?(model_id)
    if not more? and model_id, do: Lineage.prune(model_id)
    more?
  end

  defp config(key),
    do: Application.get_env(:knowseek, Knowseek.Documents.Reembed, []) |> Keyword.fetch!(key)
end
