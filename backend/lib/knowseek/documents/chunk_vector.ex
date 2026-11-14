defmodule Knowseek.Documents.ChunkVector do
  @moduledoc """
  A chunk's embedding, in the sqlite-vec table `chunk_vectors`
  (`vec0`, `float[1024]`, cosine distance). `rowid` is the chunk's `seq`.
  `embedding_model_id` is the partition key: the id of the model that made the
  vector (`Knowseek.Documents.EmbeddingModel`), the same as on the chunk's
  document. A search compares only vectors of one model (#84, ADR 0035).

  `Knowseek.Documents` inserts the row together with its chunk, and replaces
  it (delete, then insert under the same `rowid`: a partition key cannot be
  updated) when a re-embed changes the model. A trigger on `chunks` deletes it
  with the chunk, also when a document delete cascades.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:rowid, :integer, autogenerate: false}
  schema "chunk_vectors" do
    field :embedding_model_id, :integer
    field :embedding, Knowseek.Documents.Vector
  end
end
