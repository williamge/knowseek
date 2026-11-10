defmodule Knowseek.Repo.Migrations.SqliteBaseline do
  use Ecto.Migration

  # The whole schema on SQLite (ADR 0030). It replaces the Postgres
  # migrations, which are in the git history before this file: no Postgres
  # database is upgraded, its documents are discovered again. UUIDs and
  # timestamps are TEXT, maps (metadata, attribution) are JSON TEXT.

  # Must match the :dimensions config for Knowseek.Embeddings (AGENTS.md, rule 7).
  @dimensions 1024

  def up do
    # Oban picks its SQLite tables from the repo's adapter.
    Oban.Migration.up()

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
      # Page views per 30 days of the page; nullable (ADR 0018).
      add :monthly_views, :bigint
      # When the source says the page was last edited; nullable.
      add :source_updated_at, :utc_datetime
      # License, credit, whether the text differs from the source's, and what
      # a peer may receive (ADR 0026).
      add :license, :string, null: false, default: "LicenseRef-unknown"
      add :attribution, :map
      add :modified, :boolean, null: false, default: false

      add :share, :string,
        null: false,
        default: "none",
        check: %{name: "documents_share_check", expr: "share IN ('full', 'pointer', 'none')"}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:documents, [:url])
    # Ingest looks up a document by body hash when its URL is new.
    create index(:documents, [:content_hash])

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

    # Documents are split into chunks. Chunks are the unit of search. `seq`
    # is the INTEGER PRIMARY KEY, so it is the rowid and a VACUUM never
    # renumbers it: the two search tables below key on it. `id` is the UUID
    # that the API shows.
    create table(:chunks, primary_key: false) do
      add :seq, :integer, primary_key: true
      add :id, :binary_id, null: false

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:chunks, [:id])
    create unique_index(:chunks, [:document_id, :position])

    # Full-text search: an external-content FTS5 table over chunks.content
    # (the text is stored once, in chunks). The Porter stemmer over unicode61,
    # accents kept, as Postgres's `english` configuration did.
    execute """
    CREATE VIRTUAL TABLE chunks_fts USING fts5(
      content, content='chunks', content_rowid='seq',
      tokenize='porter unicode61 remove_diacritics 0'
    )
    """

    # Vector search: an exact scan over float32 vectors, cosine distance.
    execute """
    CREATE VIRTUAL TABLE chunk_vectors USING vec0(
      embedding float[#{@dimensions}] distance_metric=cosine
    )
    """

    # The triggers keep both tables in step with chunks, also when a document
    # delete cascades to its chunks.
    execute """
    CREATE TRIGGER chunks_after_insert AFTER INSERT ON chunks BEGIN
      INSERT INTO chunks_fts(rowid, content) VALUES (new.seq, new.content);
    END
    """

    execute """
    CREATE TRIGGER chunks_after_delete AFTER DELETE ON chunks BEGIN
      INSERT INTO chunks_fts(chunks_fts, rowid, content) VALUES ('delete', old.seq, old.content);
      DELETE FROM chunk_vectors WHERE rowid = old.seq;
    END
    """

    execute """
    CREATE TRIGGER chunks_after_update AFTER UPDATE OF content ON chunks BEGIN
      INSERT INTO chunks_fts(chunks_fts, rowid, content) VALUES ('delete', old.seq, old.content);
      INSERT INTO chunks_fts(rowid, content) VALUES (new.seq, new.content);
    END
    """
  end

  def down do
    execute "DROP TRIGGER chunks_after_update"
    execute "DROP TRIGGER chunks_after_delete"
    execute "DROP TRIGGER chunks_after_insert"
    execute "DROP TABLE chunk_vectors"
    execute "DROP TABLE chunks_fts"
    drop table(:chunks)
    drop table(:document_aliases)
    drop table(:documents)
    Oban.Migration.down()
  end
end
