defmodule Knowseek.Repo.Migrations.AddNormalizedQueryToTopics do
  use Ecto.Migration

  # Topics become unique by their normalized query (lowercase, collapsed
  # whitespace). The topics feature was removed (ADR 0015) and a later
  # migration drops the table, so the old data step that backfilled the column
  # and merged duplicate rows is gone. Rows that exist when this migration
  # runs are deleted: that only happens on a database that has not migrated
  # past it yet, and the topics table is dropped later in the same run.
  #
  # The unique index is on `md5(normalized_query)`, not on the column: a btree
  # entry cannot exceed about 2.7 kB, and a 1000-character query in a
  # multibyte script is larger. An index on the hash has a fixed entry size, so
  # no existing or future row can fail it.
  def up do
    execute "DELETE FROM topics"

    alter table(:topics) do
      add :normalized_query, :text
    end

    flush()

    alter table(:topics) do
      modify :normalized_query, :text, null: false
    end

    create unique_index(:topics, ["md5(normalized_query)"],
             name: :topics_normalized_query_md5_index
           )
  end

  # The merge of duplicate topics cannot be undone.
  def down do
    drop unique_index(:topics, ["md5(normalized_query)"],
           name: :topics_normalized_query_md5_index
         )

    alter table(:topics) do
      remove :normalized_query
    end
  end
end
