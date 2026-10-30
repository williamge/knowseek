defmodule Knowseek.Topics.Topic do
  @moduledoc """
  Something a user wants to stay informed about. Active topics are
  refreshed (discovery runs again) every `refresh_interval_seconds`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "topics" do
    field :query, :string
    field :active, :boolean, default: true
    field :refresh_interval_seconds, :integer, default: 86_400
    field :last_refreshed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(topic, attrs) do
    topic
    |> cast(attrs, [:query, :active, :refresh_interval_seconds])
    |> validate_required([:query])
    |> validate_length(:query, min: 2, max: 1_000)
    |> validate_number(:refresh_interval_seconds, greater_than_or_equal_to: 900)
  end
end
