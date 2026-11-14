defmodule Knowseek.Activity.NetworkUsage do
  @moduledoc """
  Bytes Knowseek downloaded from one source on one UTC day (response headers
  and bodies as received; ADR 0031, ADR 0034), keyed by `{day, source}`.
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
