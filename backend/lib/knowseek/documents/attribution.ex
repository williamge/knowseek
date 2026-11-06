defmodule Knowseek.Documents.Attribution do
  @moduledoc """
  Who to credit for a document, and where (ADR 0026). Stored as jsonb in
  `documents.attribution`.

  `url` is the page that credits the authors (for Wikipedia, the article).
  `credit` is the name to show ("Wikipedia"). `authors` lists names only where
  the license needs them, and is empty otherwise.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{url: String.t(), credit: String.t(), authors: [String.t()]}

  @primary_key false
  embedded_schema do
    field :url, :string
    field :credit, :string
    field :authors, {:array, :string}, default: []
  end

  def changeset(attribution, attrs) do
    attribution
    |> cast(attrs, [:url, :credit, :authors])
    |> validate_required([:url, :credit])
  end
end
