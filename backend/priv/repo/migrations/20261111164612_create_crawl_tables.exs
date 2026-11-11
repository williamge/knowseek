defmodule Knowseek.Repo.Migrations.CreateCrawlTables do
  use Ecto.Migration

  def change do
    # A source page whose links were read (#89, ADR 0033): a page your searches
    # showed. `link_ids` holds the page ids of all its links, for the shared-link
    # count. A rowid table: the JSON list is too long for a WITHOUT ROWID row.
    create table(:crawl_sources, primary_key: false) do
      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :site, :string, null: false
      add :link_ids, {:array, :integer}, null: false
      add :links, :integer, null: false
      add :kept, :integer, null: false
      add :read_at, :utc_datetime, null: false
    end

    # A scored link (#89): pending, fetched (then it is the provenance of a
    # background page) or skipped. One row per source page and linked page.
    create table(:crawl_candidates, primary_key: false, options: "WITHOUT ROWID") do
      add :source_document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :page_id, :integer, null: false, primary_key: true
      add :site, :string, null: false
      add :title, :text, null: false
      add :description, :text
      add :url, :text, null: false
      add :interest, :float, null: false
      add :novelty, :float, null: false
      add :gap, :float, null: false, default: 0.0
      add :shared, :float, null: false, default: 0.0
      add :shared_count, :integer, null: false, default: 1
      add :score, :float, null: false

      add :state, :string,
        null: false,
        default: "pending",
        check: %{
          name: "crawl_candidates_state_check",
          expr: "state IN ('pending', 'fetched', 'skipped')"
        }

      add :document_id, :binary_id
      add :stored_bytes, :integer
      add :scored_at, :utc_datetime, null: false
      add :fetched_at, :utc_datetime
      add :failed_at, :utc_datetime
    end

    create index(:crawl_candidates, [:site, :page_id])
    create index(:crawl_candidates, [:state, :fetched_at])

    # "Which of these page ids are indexed" must not read the bodies: `metadata`
    # sits behind `body` in the row.
    create index(:documents, ["source", "json_extract(metadata, '$.pageid')"],
             name: :documents_source_pageid_index
           )
  end
end
