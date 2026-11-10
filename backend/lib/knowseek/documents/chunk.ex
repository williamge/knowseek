defmodule Knowseek.Documents.Chunk do
  @moduledoc """
  A slice of a document's body. Chunks are the unit of search.

  `id` (a UUID) is the chunk's identity in the API. `seq` is the integer key
  that SQLite assigns on insert (the table's `INTEGER PRIMARY KEY`, so a
  `VACUUM` never renumbers it). The two search tables key on it: the FTS5
  table `chunks_fts` (full-text search, kept in sync by triggers) and the
  sqlite-vec table `chunk_vectors` (`Knowseek.Documents.ChunkVector`, the
  embedding). See ADR 0030.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "chunks" do
    field :seq, :integer, writable: :never
    field :position, :integer
    field :content, :string

    belongs_to :document, Knowseek.Documents.Document

    timestamps(type: :utc_datetime)
  end
end
