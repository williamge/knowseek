defmodule Knowseek.Crawl.Candidate do
  @moduledoc """
  A scored link (#89, ADR 0033): `pending`, `fetched` (then it is the
  provenance of a background page) or `skipped`. One row per source page and
  linked page. There is no `belongs_to`: the crawl never joins `documents`
  (rule 1 of `AGENTS.md`). `Knowseek.Crawl` is the only writer.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "crawl_candidates" do
    field :source_document_id, :binary_id, primary_key: true
    field :page_id, :integer, primary_key: true
    field :site, :string
    field :title, :string
    field :description, :string
    field :url, :string
    field :interest, :float
    field :novelty, :float
    field :gap, :float, default: 0.0
    field :shared, :float, default: 0.0
    field :shared_count, :integer, default: 1
    field :score, :float
    field :state, :string, default: "pending"
    field :document_id, :binary_id
    field :stored_bytes, :integer
    field :scored_at, :utc_datetime
    field :fetched_at, :utc_datetime
    field :failed_at, :utc_datetime
  end
end
