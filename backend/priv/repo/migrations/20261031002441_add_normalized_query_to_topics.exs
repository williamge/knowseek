defmodule Knowseek.Repo.Migrations.AddNormalizedQueryToTopics do
  use Ecto.Migration

  # Topics become unique by `Knowseek.Discovery.normalize/1` of their query.
  # `Knowseek.Topics.Deduplicate` backfills the column and merges the rows
  # that already share a normalized query; its moduledoc has the merge rule.
  #
  # The unique index is on `md5(normalized_query)`, not on the column: a btree
  # entry cannot exceed about 2.7 kB, and a 1000-character query in a
  # multibyte script is larger. An index on the hash has a fixed entry size, so
  # no existing or future row can fail it.
  def up do
    alter table(:topics) do
      add :normalized_query, :text
    end

    flush()

    Knowseek.Topics.Deduplicate.run(repo())

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
