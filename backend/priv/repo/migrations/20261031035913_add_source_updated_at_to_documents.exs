defmodule Knowseek.Repo.Migrations.AddSourceUpdatedAtToDocuments do
  use Ecto.Migration

  def change do
    # When the source says the page was last edited (for Wikipedia, the
    # timestamp of the latest revision). Nullable: most sources have no such
    # figure. Not `published_at` (when it was first published) and not
    # `fetched_at` (when we last saw it).
    alter table(:documents) do
      add :source_updated_at, :utc_datetime
    end
  end
end
