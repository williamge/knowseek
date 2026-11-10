defmodule Knowseek.ReleaseTest do
  # Not async: it switches the sandbox pool to :auto for the whole suite.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Knowseek.Release
  alias Knowseek.ReleaseRepo
  alias Knowseek.Repo

  @moduletag :tmp_dir

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

  # Points ReleaseRepo at the SQLite file `path`.
  defp configure_release_repo(path) do
    Application.put_env(:knowseek, ReleaseRepo,
      database: path,
      priv: "priv/repo",
      pool_size: 1,
      load_extensions: [Repo.sqlite_vec()]
    )

    on_exit(fn -> Application.delete_env(:knowseek, ReleaseRepo) end)
    path
  end

  defp migration_count do
    {:ok, count, _} =
      Ecto.Migrator.with_repo(ReleaseRepo, fn repo ->
        %{rows: [[count]]} = SQL.query!(repo, "SELECT count(*) FROM schema_migrations", [])
        count
      end)

    count
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
    test "creates a missing database file and its directory, then migrates it", %{tmp_dir: dir} do
      path = configure_release_repo(Path.join([dir, "data", "knowseek.db"]))
      refute File.exists?(path)

      assert Release.migrate([ReleaseRepo]) == :ok

      assert File.exists?(path)
      assert migration_count() > 0
    end

    test "migrates an existing database without recreating it", %{tmp_dir: dir} do
      configure_release_repo(Path.join(dir, "knowseek.db"))
      assert Release.migrate([ReleaseRepo]) == :ok
      count = migration_count()

      # A table that a recreated file would not have.
      {:ok, _, _} =
        Ecto.Migrator.with_repo(ReleaseRepo, fn repo ->
          SQL.query!(repo, "CREATE TABLE marker (x INTEGER)", [])
        end)

      assert Release.migrate([ReleaseRepo]) == :ok

      assert migration_count() == count

      {:ok, %{rows: [[1]]}, _} =
        Ecto.Migrator.with_repo(ReleaseRepo, fn repo ->
          SQL.query!(repo, "SELECT count(*) FROM sqlite_master WHERE name = 'marker'", [])
        end)
    end

    test "fails when the file cannot be created", %{tmp_dir: dir} do
      # A regular file where the directory should be.
      blocker = Path.join(dir, "not_a_directory")
      File.write!(blocker, "")
      configure_release_repo(Path.join(blocker, "knowseek.db"))

      assert_raise MatchError, fn -> Release.migrate([ReleaseRepo]) end
    end
  end

  describe "rollback/2" do
    test "reverts migrations down to the given version", %{tmp_dir: dir} do
      configure_release_repo(Path.join(dir, "knowseek.db"))
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
