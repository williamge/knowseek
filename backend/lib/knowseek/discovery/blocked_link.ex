defmodule Knowseek.Discovery.BlockedLink do
  @moduledoc "A link from an indexed page to a host off the allowlist (#88, ADR 0032). `Knowseek.Discovery` is the only writer."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "blocked_links" do
    field :document_id, :binary_id, primary_key: true
    field :url, :string, primary_key: true
    field :host, :string
    field :first_seen_at, :utc_datetime
    field :times_seen, :integer, default: 1
  end
end
