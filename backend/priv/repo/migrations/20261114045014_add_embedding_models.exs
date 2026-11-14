defmodule Knowseek.Repo.Migrations.AddEmbeddingModels do
  use Ecto.Migration

  # Which model made which vectors (#84, ADR 0035).

  # Must match the baseline migration and the :dimensions config (AGENTS.md, rule 7).
  @dimensions 1024

  def up do
    # One row per model that made vectors stored here. `digest` is "" for a
    # provider that has none.
    create table(:embedding_models, primary_key: false) do
      add :id, :integer, primary_key: true
      add :name, :string, null: false
      add :digest, :string, null: false, default: ""
      add :dimensions, :integer, null: false
      add :quantization, :string, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:embedding_models, [:name, :digest, :dimensions, :quantization])

    # The model that made the page's vectors. NULL: none that is known.
    alter table(:documents) do
      add :embedding_model_id, references(:embedding_models, on_delete: :nilify_all)
    end

    create index(:documents, [:embedding_model_id])

    # vec0 cannot add a column, and a renamed vec0 table is broken (sqlite-vec
    # 0.1.9), so the table is dropped and created again. The stored vectors
    # have no known model: they are not copied, and the first start re-embeds
    # every page (ADR 0035). The triggers on `chunks` name the table and keep
    # working.
    execute "DROP TABLE chunk_vectors"

    execute """
    CREATE VIRTUAL TABLE chunk_vectors USING vec0(
      embedding_model_id integer partition key,
      embedding float[#{@dimensions}] distance_metric=cosine
    )
    """
  end

  def down do
    # Back to one table without a model: every stored vector is kept, whatever
    # model made it (the code before this migration does not tell them apart).
    execute "CREATE TABLE chunk_vectors_backup AS SELECT rowid AS seq, embedding FROM chunk_vectors"
    execute "DROP TABLE chunk_vectors"

    execute """
    CREATE VIRTUAL TABLE chunk_vectors USING vec0(
      embedding float[#{@dimensions}] distance_metric=cosine
    )
    """

    execute "INSERT INTO chunk_vectors(rowid, embedding) SELECT seq, embedding FROM chunk_vectors_backup"
    execute "DROP TABLE chunk_vectors_backup"

    drop index(:documents, [:embedding_model_id])

    alter table(:documents) do
      remove :embedding_model_id
    end

    drop table(:embedding_models)
  end
end
