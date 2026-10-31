defmodule Knowseek.Repo.Migrations.AddNormalizedQueryToTopics do
  use Ecto.Migration

  # Topics become unique by `Knowseek.Discovery.normalize/1` of their query.
  # `Knowseek.Topics.Deduplicate` backfills the column and merges the rows
  # that already share a normalized query; its moduledoc has the merge rule.
  def up do
    alter table(:topics) do
      add :normalized_query, :text
    end

    flush()

    Knowseek.Topics.Deduplicate.run(repo())

    alter table(:topics) do
      modify :normalized_query, :text, null: false
    end

    create unique_index(:topics, [:normalized_query])
  end

  # The merge of duplicate topics cannot be undone.
  def down do
    drop unique_index(:topics, [:normalized_query])

    alter table(:topics) do
      remove :normalized_query
    end
  end
end
