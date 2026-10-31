defmodule Knowseek.ReleaseTest do
  # Not async: it switches the sandbox pool to :auto for the whole suite.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.Postgres
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Knowseek.Release
  alias Knowseek.ReleaseRepo
  alias Knowseek.Repo

  setup do
    Sandbox.mode(Repo, :auto)

    # Every run of a migration compiles its file again; keep the redefinition
    # warnings out of the test output.
    Code.put_compiler_option(:ignore_module_conflict, true)

    on_exit(fn ->
      Code.put_compiler_option(:ignore_module_conflict, false)
      Sandbox.mode(Repo, :manual)
    end)
  end

  # Points ReleaseRepo at `database`, as `username` (default: the test user).
  defp configure_release_repo(database, overrides \\ []) do
    base = Keyword.take(Repo.config(), [:username, :password, :hostname, :port, :types])

    config =
      base
      |> Keyword.put(:database, database)
      |> Keyword.put(:priv, "priv/repo")
      |> Keyword.merge(overrides)

    Application.put_env(:knowseek, ReleaseRepo, config)
    on_exit(fn -> Application.delete_env(:knowseek, ReleaseRepo) end)
    config
  end

  defp database_exists?(name) do
    %{rows: rows} = SQL.query!(Repo, "SELECT 1 FROM pg_database WHERE datname = $1", [name])
    rows != []
  end

  defp migration_count do
    {:ok, count, _} =
      Ecto.Migrator.with_repo(ReleaseRepo, fn repo ->
        %{rows: [[count]]} = SQL.query!(repo, "SELECT count(*) FROM schema_migrations", [])
        count
      end)

    count
  end

  # A role that may log in and migrate the test database but not create databases.
  defp restricted_role do
    role = "knowseek_release_test_role_#{System.unique_integer([:positive])}"

    SQL.query!(Repo, "CREATE ROLE #{role} LOGIN PASSWORD 'pw' NOCREATEDB NOSUPERUSER", [])
    SQL.query!(Repo, "GRANT ALL ON SCHEMA public TO #{role}", [])
    SQL.query!(Repo, "GRANT ALL ON ALL TABLES IN SCHEMA public TO #{role}", [])

    on_exit(fn ->
      SQL.query!(Repo, "REVOKE ALL ON ALL TABLES IN SCHEMA public FROM #{role}", [])
      SQL.query!(Repo, "REVOKE ALL ON SCHEMA public FROM #{role}", [])
      SQL.query!(Repo, "DROP ROLE #{role}", [])
    end)

    role
  end

  defp throwaway_database do
    name = "knowseek_release_test_#{System.unique_integer([:positive])}"
    config = configure_release_repo(name)
    on_exit(fn -> Postgres.storage_down(config) end)
    name
  end

  describe "migrate/0" do
    test "is a no-op when the database exists and is migrated" do
      %{rows: [[before_count]]} = SQL.query!(Repo, "SELECT count(*) FROM schema_migrations", [])

      assert Release.migrate() == :ok

      %{rows: [[after_count]]} = SQL.query!(Repo, "SELECT count(*) FROM schema_migrations", [])
      assert after_count == before_count
      assert before_count > 0
    end
  end

  describe "migrate/1" do
    test "creates a missing database, then migrates it" do
      name = throwaway_database()
      refute database_exists?(name)

      assert Release.migrate([ReleaseRepo]) == :ok

      assert database_exists?(name)
      assert migration_count() > 0
    end

    test "migrates an existing database without recreating it" do
      name = throwaway_database()
      assert Release.migrate([ReleaseRepo]) == :ok
      count = migration_count()

      assert Release.migrate([ReleaseRepo]) == :ok

      assert database_exists?(name)
      assert migration_count() == count
    end

    test "leaves an existing database alone when the user may not create databases" do
      role = restricted_role()
      configure_release_repo(Repo.config()[:database], username: role, password: "pw")

      log = capture_log(fn -> assert Release.migrate([ReleaseRepo]) == :ok end)

      refute log =~ "Could not create database"
      assert migration_count() > 0
    end

    test "logs a warning, then fails in the migration step, when it may not create the database" do
      role = restricted_role()
      name = "knowseek_release_test_#{System.unique_integer([:positive])}"
      # A short queue makes the failing migration step give up quickly.
      configure_release_repo(name,
        username: role,
        password: "pw",
        queue_target: 200,
        queue_interval: 200
      )

      log =
        capture_log(fn ->
          assert_raise DBConnection.ConnectionError, fn ->
            Release.migrate([ReleaseRepo])
          end
        end)

      assert log =~ "Could not create database"
      refute database_exists?(name)
    end
  end

  describe "rollback/2" do
    test "reverts migrations down to the given version" do
      throwaway_database()
      assert Release.migrate([ReleaseRepo]) == :ok

      {:ok, first, _} =
        Ecto.Migrator.with_repo(ReleaseRepo, fn repo ->
          %{rows: [[version]]} =
            SQL.query!(repo, "SELECT min(version) FROM schema_migrations", [])

          version
        end)

      Release.rollback(ReleaseRepo, first)

      assert migration_count() == 0
    end
  end
end
