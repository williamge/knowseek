defmodule Knowseek.Activity.SearchHit do
  @moduledoc """
  One of the top results of a logged search (#96, ADR 0031), keyed by
  `{search_id, rank}`. `document_id` has no foreign key: the history survives
  a deleted document, and `Knowseek.Activity` never joins `documents`.
  `positions` are the `chunks.position` of the best chunk, then of the
  passages shown. `background` copies "the document's origin was
  `background`" at the time of the search.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "search_hits" do
    field :search_id, :id, primary_key: true
    field :rank, :integer, primary_key: true
    field :document_id, :binary_id
    field :positions, {:array, :integer}
    field :background, :boolean, default: false
  end
end
