defmodule Knowseek.Release do
  @moduledoc """
  Release tasks that run without Mix: `bin/migrate` calls `migrate/0`.

  The container starts with `bin/migrate && bin/server` (see
  `docs/decisions/0014-release-and-container.md`).
  """
  require Logger

  @app :knowseek

  @doc """
  Creates the database if it is missing, then runs all pending migrations.

  Creating is best effort: a managed database often exists already and the
  user may not be allowed to create databases. Then the migration step is the
  one that fails, with the real connection error. The first migration runs
  `CREATE EXTENSION vector`, which needs a superuser or an already enabled
  extension.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      create_database(repo)
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp create_database(repo) do
    case repo.__adapter__().storage_up(repo.config()) do
      :ok -> Logger.info("Created database for #{inspect(repo)}")
      {:error, :already_up} -> :ok
      {:error, reason} -> Logger.warning("Could not create database: #{inspect(reason)}")
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
