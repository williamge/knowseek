defmodule Knowseek.Repo.Migrations.CreateDocumentAliases do
  use Ecto.Migration

  def change do
    # Other canonical URLs that served the same body as a document.
    create table(:document_aliases, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :url, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:document_aliases, [:url])
    create index(:document_aliases, [:document_id])

    # Ingest looks up a document by body hash when its URL is new.
    create index(:documents, [:content_hash])
  end
end
