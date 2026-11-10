defmodule Knowseek.Release do
  @moduledoc """
  Release tasks that run without Mix: `bin/migrate` calls `migrate/0`.

  The container starts with `bin/migrate && bin/server` (see
  `docs/decisions/0014-release-and-container.md`). The database is the SQLite
  file at `DATABASE_PATH` (ADR 0030).
  """
  require Logger

  @app :knowseek

  @doc """
  Creates the database file (and its directory) if it is missing, then runs
  all pending migrations.
  """
  def migrate, do: migrate(repos())

  @doc """
  Like `migrate/0`, for the given repos. A file that cannot be created (a
  directory that is not writable) raises, so `bin/migrate` fails.
  """
  def migrate(repos) when is_list(repos) do
    load_app()

    for repo <- repos do
      create_database(repo)
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Rolls back `repo` down to and including migration `version`."
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp create_database(repo) do
    case repo.__adapter__().storage_up(repo.config()) do
      :ok -> Logger.info("Created database for #{inspect(repo)}")
      {:error, :already_up} -> :ok
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_loaded(@app)
  end
end
