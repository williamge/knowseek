defmodule Knowseek.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. A test that uses the
  database must not be async (SQLite, ADR 0030): see
  `setup_sandbox/1`.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Knowseek.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Knowseek.DataCase
      import Knowseek.Fixtures
      use Oban.Testing, repo: Knowseek.Repo, engine: Oban.Engines.Lite
    end
  end

  setup tags do
    Knowseek.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.

  Only a test that is not async gets a sandbox connection, in shared mode.
  SQLite has one writer, and the sandbox holds a transaction (IMMEDIATE, so
  with the write lock) for the whole test, so two owners at once would wait
  on each other. An async test gets no connection: if it touches the
  database, it fails with an ownership error.
  """
  def setup_sandbox(tags) do
    if !tags[:async] do
      pid = Sandbox.start_owner!(Knowseek.Repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(pid) end)
    end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
