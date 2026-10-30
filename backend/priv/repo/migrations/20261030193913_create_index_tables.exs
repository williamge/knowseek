defmodule Knowseek.Repo.Migrations.CreateIndexTables do
  use Ecto.Migration

  # Must match the :dimensions config for Knowseek.Embeddings.
  @dimensions 1024

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    # One row per piece of source content (a web page, an article, a manual note).
    create table(:documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :url, :text, null: false
      add :title, :text
      add :body, :text, null: false
      # Name of the source that produced the document, e.g. "manual".
      add :source, :string, null: false
      add :content_hash, :string, null: false
      add :published_at, :utc_datetime
      add :fetched_at, :utc_datetime, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:documents, [:url])

    # Documents are split into chunks. Chunks are the unit of search.
    create table(:chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false
      add :content, :text, null: false
      add :embedding, :vector, size: @dimensions

      timestamps(type: :utc_datetime)
    end

    execute """
    ALTER TABLE chunks
      ADD COLUMN search_vector tsvector
      GENERATED ALWAYS AS (to_tsvector('english', content)) STORED
    """

    create unique_index(:chunks, [:document_id, :position])
    create index(:chunks, [:search_vector], using: "GIN")
    create index(:chunks, ["embedding vector_cosine_ops"], using: "hnsw")

    # Things a user wants to stay informed about. Refreshed on a schedule.
    create table(:topics, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :query, :text, null: false
      add :active, :boolean, null: false, default: true
      add :refresh_interval_seconds, :integer, null: false, default: 86_400
      add :last_refreshed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:topics, [:active, :last_refreshed_at])
  end

  def down do
    drop table(:topics)
    drop table(:chunks)
    drop table(:documents)
    execute "DROP EXTENSION IF EXISTS vector"
  end
end
