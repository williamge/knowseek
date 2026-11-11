defmodule Knowseek.Activity.SearchRecord do
  @moduledoc """
  One logged search (#96, ADR 0031): the normalized query, the coverage as
  first assessed, and the time of the first request (`inserted_at`). Named
  apart from the `Knowseek.Search` context. Only `Knowseek.Activity` uses it.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :id, autogenerate: true}
  schema "searches" do
    field :query, :string
    field :coverage, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
