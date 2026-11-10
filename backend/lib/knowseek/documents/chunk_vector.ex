defmodule Knowseek.Documents.ChunkVector do
  @moduledoc """
  A chunk's embedding, in the sqlite-vec table `chunk_vectors`
  (`vec0`, `float[1024]`, cosine distance). `rowid` is the chunk's `seq`.

  `Knowseek.Documents` inserts the row together with its chunk. A trigger on
  `chunks` deletes it with the chunk, also when a document delete cascades.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:rowid, :integer, autogenerate: false}
  schema "chunk_vectors" do
    field :embedding, Knowseek.Documents.Vector
  end
end
