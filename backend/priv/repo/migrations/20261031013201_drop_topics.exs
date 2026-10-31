defmodule Knowseek.Repo.Migrations.DropTopics do
  use Ecto.Migration

  # The topics feature was removed (docs/decisions/0015-remove-topics.md).
  # Jobs of the removed workers are deleted too: left in `oban_jobs`, they
  # would fail forever with an unknown worker.
  def up do
    execute "DELETE FROM oban_jobs WHERE worker IN ('Knowseek.Topics.RefreshWorker', 'Knowseek.Topics.CheckWorker')"

    drop table(:topics)
  end

  # Recreates the final schema of the table. The rows are not restored.
  def down do
    create table(:topics, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :query, :text, null: false
      add :normalized_query, :text, null: false
      add :active, :boolean, null: false, default: true
      add :refresh_interval_seconds, :integer, null: false, default: 86_400
      add :max_age_seconds, :integer
      add :last_refreshed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:topics, [:active, :last_refreshed_at])

    create unique_index(:topics, ["md5(normalized_query)"],
             name: :topics_normalized_query_md5_index
           )
  end
end
