defmodule Knowseek.ReleaseTest do
  # Not async: it switches the sandbox pool to :auto for the whole suite.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Knowseek.Repo

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
  end

  describe "migrate/0" do
    test "is a no-op when the database exists and is migrated" do
      %{rows: [[before_count]]} = SQL.query!(Repo, "SELECT count(*) FROM schema_migrations", [])

      assert Knowseek.Release.migrate() == :ok

      %{rows: [[after_count]]} = SQL.query!(Repo, "SELECT count(*) FROM schema_migrations", [])
      assert after_count == before_count
      assert before_count > 0
    end
  end
end
