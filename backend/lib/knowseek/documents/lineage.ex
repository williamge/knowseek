defmodule Knowseek.Documents.Lineage do
  @moduledoc """
  The model rows and the "stale" queries of `Knowseek.Documents` (#84, ADR
  0035). Internal: only `Knowseek.Documents` and its re-embed code call it.

  A page is *stale* when its `embedding_model_id` is not the current model's,
  or is NULL (the migration leaves it so). In SQL that is
  `embedding_model_id IS NOT ?1`. When the current model has no row yet, `?1`
  is bound as `-1`, never as NULL: `NULL IS NOT NULL` is false, and the pages
  that the migration left with NULL would then never count as stale. With `-1`
  every page is stale, which is right: no vector of this model exists.
  """
  import Ecto.Query

  alias Knowseek.Documents.{Chunk, Document, EmbeddingModel, Vector}
  alias Knowseek.Embeddings
  alias Knowseek.Repo

  @doc "The id of `model`'s row, or nil when no vector of it was ever stored. Only reads."
  @spec model_id(Embeddings.model()) :: pos_integer() | nil
  def model_id(model) do
    Repo.one(
      from m in EmbeddingModel,
        where:
          m.name == ^model.name and m.digest == ^model.digest and
            m.dimensions == ^model.dimensions and m.quantization == ^Vector.quantization(),
        select: m.id
    )
  end

  @doc "The id of `model`'s row, inserting the row first if needed. Call inside the write transaction."
  @spec ensure_model!(Embeddings.model()) :: pos_integer()
  def ensure_model!(model) do
    row = %{
      name: model.name,
      digest: model.digest,
      dimensions: model.dimensions,
      quantization: Vector.quantization(),
      inserted_at: DateTime.utc_now(:second)
    }

    Repo.insert_all(EmbeddingModel, [row],
      on_conflict: :nothing,
      conflict_target: [:name, :digest, :dimensions, :quantization]
    )

    model_id(model)
  end

  @doc "When `model_id`'s row was created, or nil."
  @spec inserted_at(pos_integer() | nil) :: DateTime.t() | nil
  def inserted_at(nil), do: nil

  def inserted_at(model_id),
    do: Repo.one(from m in EmbeddingModel, where: m.id == ^model_id, select: m.inserted_at)

  @doc "Whether a page has vectors of another model than `model_id`, or of none."
  @spec stale?(pos_integer() | nil) :: boolean()
  def stale?(model_id) do
    %{rows: [[exists]]} =
      Repo.query!(
        "SELECT EXISTS(SELECT 1 FROM documents WHERE embedding_model_id IS NOT ?1)",
        [bind(model_id)]
      )

    exists == 1
  end

  @doc "Up to `limit` ids of such pages, the page with the oldest first passage first."
  @spec stale_document_ids(pos_integer() | nil, pos_integer()) :: [Ecto.UUID.t()]
  def stale_document_ids(model_id, limit) do
    Repo.query!(
      """
      SELECT d.id FROM documents AS d
      LEFT JOIN chunks AS c ON c.document_id = d.id
      WHERE d.embedding_model_id IS NOT ?1
      GROUP BY d.id
      ORDER BY coalesce(min(c.seq), 0), d.id
      LIMIT ?2
      """,
      [bind(model_id), limit]
    ).rows
    |> Enum.map(fn [id] -> id end)
  end

  @doc "How many passages there are, and how many belong to pages of `model_id`."
  @spec passages(pos_integer() | nil) :: %{total: non_neg_integer(), current: non_neg_integer()}
  def passages(model_id) do
    # Never count in `chunk_vectors`: that scans the vectors.
    total = Repo.aggregate(Chunk, :count)

    current =
      if model_id do
        Repo.one(
          from c in Chunk,
            join: d in Document,
            on: d.id == c.document_id,
            where: d.embedding_model_id == ^model_id,
            select: count()
        )
      else
        0
      end

    %{total: total, current: current}
  end

  @doc "Deletes the model rows that no page uses, except `model_id`."
  @spec prune(pos_integer()) :: :ok
  def prune(model_id) do
    Repo.delete_all(
      from m in EmbeddingModel,
        where:
          m.id != ^model_id and
            m.id not in subquery(
              from d in Document,
                where: not is_nil(d.embedding_model_id),
                select: d.embedding_model_id
            )
    )

    :ok
  end

  defp bind(nil), do: -1
  defp bind(model_id), do: model_id
end
