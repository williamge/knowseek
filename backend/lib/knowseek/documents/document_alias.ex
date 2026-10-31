defmodule Knowseek.Documents.DocumentAlias do
  @moduledoc """
  Another canonical URL that served the same body as a document.

  Ingesting a URL that is an alias of a document updates that document.
  `Knowseek.Documents.ingest/1` is the only writer.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "document_aliases" do
    field :url, :string
    belongs_to :document, Knowseek.Documents.Document

    timestamps(type: :utc_datetime)
  end

  def changeset(alias_record, attrs) do
    alias_record
    |> cast(attrs, [:url, :document_id])
    |> validate_required([:url, :document_id])
    |> unique_constraint(:url)
    |> foreign_key_constraint(:document_id)
  end
end
