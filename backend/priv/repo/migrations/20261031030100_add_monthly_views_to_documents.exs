defmodule Knowseek.Repo.Migrations.AddMonthlyViewsToDocuments do
  use Ecto.Migration

  def change do
    # Page views per 30 days of the page a document came from. Nullable:
    # most documents have no such signal. Search turns it into a ranking
    # prior (ADR 0018).
    alter table(:documents) do
      add :monthly_views, :bigint
    end
  end
end
