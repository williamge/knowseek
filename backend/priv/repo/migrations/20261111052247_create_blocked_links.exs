defmodule Knowseek.Repo.Migrations.CreateBlockedLinks do
  use Ecto.Migration

  def change do
    # Links to hosts off the allowlist (#88, ADR 0032). One row per page and
    # URL. WITHOUT ROWID: the primary key is the table, so the key is stored once.
    create table(:blocked_links, primary_key: false, options: "WITHOUT ROWID") do
      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :url, :text, null: false, primary_key: true
      add :host, :string, null: false
      add :first_seen_at, :utc_datetime, null: false
      add :times_seen, :integer, null: false, default: 1
    end
  end
end
