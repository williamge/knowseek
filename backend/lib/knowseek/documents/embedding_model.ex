defmodule Knowseek.Documents.EmbeddingModel do
  @moduledoc "A model that made vectors stored here (#84, ADR 0035). `Knowseek.Documents` is the only writer."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :id, autogenerate: true}
  schema "embedding_models" do
    field :name, :string
    field :digest, :string, default: ""
    field :dimensions, :integer
    field :quantization, :string
    field :inserted_at, :utc_datetime
  end
end
