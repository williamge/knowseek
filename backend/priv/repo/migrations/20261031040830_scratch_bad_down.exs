defmodule Knowseek.Repo.Migrations.ScratchBadDown do
  use Ecto.Migration

  def change do
    execute "UPDATE documents SET title = upper(title)"
  end
end
