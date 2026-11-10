defmodule Knowseek.Repo do
  @moduledoc """
  The one SQLite database (ADR 0030). Every connection loads the sqlite-vec
  extension, which `mix sqlite_vec.fetch` puts in `priv/sqlite_vec/`.
  """
  use Ecto.Repo,
    otp_app: :knowseek,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_context, config) do
    {:ok, Keyword.update(config, :load_extensions, [sqlite_vec()], &[sqlite_vec() | &1])}
  end

  @doc """
  Path of the sqlite-vec extension without its file suffix (SQLite adds
  `.so` or `.dylib`).
  """
  @spec sqlite_vec() :: String.t()
  def sqlite_vec, do: Application.app_dir(:knowseek, "priv/sqlite_vec/vec0")
end
