defmodule Knowseek.Repo.Migrations.AddActivityRecord do
  use Ecto.Migration

  # The search log, the origin of each page and the network counter (#96,
  # ADR 0031).

  def up do
    # Why a page was fetched (#96, ADR 0031). Write-once at the first ingest.
    alter table(:documents) do
      add :origin, :string,
        null: false,
        default: "manual",
        check: %{
          name: "documents_origin_check",
          expr: "origin IN ('search', 'background', 'manual')"
        }

      # The normalized query whose discovery fetched the page; NULL when unknown.
      add :origin_query, :text
    end

    # The pages already indexed came from search-time discovery; their query is
    # unknown (the Oban jobs are pruned after 7 days).
    execute "UPDATE documents SET origin = 'search' WHERE source NOT IN ('manual', 'seed')"

    # Counting pages by origin must not read the bodies: `origin` sits behind
    # `body` in the row, so without this index the count walks every body's
    # overflow pages.
    create index(:documents, [:origin])

    # One row per search (#96). The time is `inserted_at`.
    create table(:searches, primary_key: false) do
      add :id, :integer, primary_key: true
      add :query, :text, null: false
      add :coverage, :string, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    # The top results of a search, at most 10. WITHOUT ROWID: the key is the table.
    create table(:search_hits, primary_key: false, options: "WITHOUT ROWID") do
      add :search_id, references(:searches, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :rank, :integer, null: false, primary_key: true
      add :document_id, :binary_id, null: false
      add :positions, {:array, :integer}, null: false
      add :background, :boolean, null: false, default: false
    end

    # Bytes downloaded per UTC day per discovery source.
    create table(:network_usage, primary_key: false, options: "WITHOUT ROWID") do
      add :day, :date, null: false, primary_key: true
      add :source, :string, null: false, primary_key: true
      add :bytes, :bigint, null: false
    end
  end

  def down do
    drop table(:network_usage)
    drop table(:search_hits)
    drop table(:searches)
    drop index(:documents, [:origin])

    alter table(:documents) do
      remove :origin_query
      remove :origin
    end
  end
end
