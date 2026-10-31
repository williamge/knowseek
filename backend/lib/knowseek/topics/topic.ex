defmodule Knowseek.Topics.Topic do
  @moduledoc """
  Something a user wants to stay informed about. Active topics are
  checked every `refresh_interval_seconds`.

  `max_age_seconds` is the freshness need of the topic. When it is set, a
  refresh seeks new data only when the index has too few documents fetched
  within `max_age_seconds`. When it is `nil`, every refresh seeks new data.

  Topics are unique by `normalized_query`, the query as
  `Knowseek.Discovery.normalize/1` returns it. `changeset/2` fills it. The
  unique index is on `md5(normalized_query)`, which has no size limit.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  # Largest value of the Postgres `integer` columns.
  @max_int 2_147_483_647

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "topics" do
    field :query, :string
    field :normalized_query, :string
    field :active, :boolean, default: true
    field :refresh_interval_seconds, :integer, default: 86_400
    field :max_age_seconds, :integer
    field :last_refreshed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(topic, attrs) do
    topic
    |> cast(attrs, [:query, :active, :refresh_interval_seconds, :max_age_seconds])
    |> validate_required([:query])
    |> validate_length(:query, min: 2, max: 1_000)
    |> validate_number(:refresh_interval_seconds,
      greater_than_or_equal_to: 900,
      less_than_or_equal_to: @max_int
    )
    |> validate_number(:max_age_seconds, greater_than: 0, less_than_or_equal_to: @max_int)
    |> put_normalized_query()
    |> unique_constraint(:normalized_query, name: :topics_normalized_query_md5_index)
  end

  defp put_normalized_query(changeset) do
    case get_change(changeset, :query) do
      nil -> changeset
      query -> put_change(changeset, :normalized_query, Knowseek.Discovery.normalize(query))
    end
  end
end
