defmodule Knowseek.Crawl.SourcePage do
  @moduledoc "A source page whose links the crawl has read (#89, ADR 0033). `Knowseek.Crawl` is the only writer."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:document_id, :binary_id, autogenerate: false}
  schema "crawl_sources" do
    field :site, :string
    field :link_ids, {:array, :integer}
    field :links, :integer
    field :kept, :integer
    field :read_at, :utc_datetime
  end
end
