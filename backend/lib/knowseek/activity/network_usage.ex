defmodule Knowseek.Activity.NetworkUsage do
  @moduledoc """
  Bytes of response bodies a discovery source downloaded on one UTC day
  (#96, ADR 0031), keyed by `{day, source}`.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "network_usage" do
    field :day, :date, primary_key: true
    field :source, :string, primary_key: true
    field :bytes, :integer
  end
end
