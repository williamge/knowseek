defmodule Knowseek.Repo.Migrations.AddMaxAgeSecondsToTopics do
  use Ecto.Migration

  # NULL means "seek new data on every refresh" (see Knowseek.Topics.Topic).
  def change do
    alter table(:topics) do
      add :max_age_seconds, :integer
    end
  end
end
