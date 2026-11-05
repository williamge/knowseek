defmodule Knowseek.Search.PgvectorCheck do
  @moduledoc """
  Stops the application from starting when the database's pgvector is too old
  for the configured HNSW iterative scan (ADR 0024).

  `hnsw.iterative_scan` exists from pgvector 0.8. On an older one Postgres
  rejects the setting, so every search would fail at request time. With
  `config :knowseek, Knowseek.Search, iterative_scan: :off` nothing is set, any
  pgvector works, and this check does nothing.

  It is a supervisor child that comes right after `Knowseek.Repo`: `start_link/1`
  runs the check and returns `:ignore` when it passes, or `{:error, exception}`,
  which fails the boot with the message. It runs when the application starts, not
  in `Knowseek.Release.migrate/0` or `mix ecto.migrate` (neither starts the
  application), so the migration that runs `CREATE EXTENSION vector` is never
  blocked by it. An application that starts on a database without the extension
  has not been migrated yet, and fails here with a message that says so.
  """

  @minimum {0, 8, 0}

  @doc false
  def child_spec(arg),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}

  @doc false
  def start_link(_arg) do
    check!()
    :ignore
  rescue
    error -> {:error, error}
  end

  @doc """
  Queries the installed pgvector version and raises `RuntimeError` when
  `check/2` fails for it. Returns `:ok` without querying for `iterative_scan: :off`.
  """
  @spec check!() :: :ok
  def check! do
    mode = Application.fetch_env!(:knowseek, Knowseek.Search) |> Keyword.fetch!(:iterative_scan)

    if mode == :off do
      :ok
    else
      %{rows: rows} =
        Knowseek.Repo.query!("SELECT extversion FROM pg_extension WHERE extname = 'vector'")

      version =
        case rows do
          [[version]] -> version
          [] -> nil
        end

      case check(version, mode) do
        :ok -> :ok
        {:error, message} -> raise message
      end
    end
  end

  @doc """
  Checks an installed pgvector version (`nil` when the extension is missing)
  against the minimum for `mode`. Returns `:ok` or `{:error, message}`.
  """
  @spec check(String.t() | nil, atom()) :: :ok | {:error, String.t()}
  def check(_version, :off), do: :ok

  def check(nil, mode) do
    {:error,
     "pgvector is not installed in the database (no `vector` extension), and " <>
       "Knowseek.Search is configured with iterative_scan: #{inspect(mode)}. " <>
       "Run the migrations, which create the extension (`mix ecto.migrate`, " <>
       "or `bin/migrate` in the release)."}
  end

  def check(version, mode) do
    case parse_version(version) do
      {:ok, parsed} when parsed >= @minimum ->
        :ok

      result ->
        shown = if match?({:ok, _}, result), do: version, else: "#{version} (unreadable)"

        {:error,
         "pgvector #{shown} is too old for Knowseek.Search iterative_scan: #{inspect(mode)}: " <>
           "it needs pgvector #{format(@minimum)} or later. Upgrade the extension " <>
           "(`ALTER EXTENSION vector UPDATE`), or set " <>
           "`config :knowseek, Knowseek.Search, iterative_scan: :off` " <>
           "(no protection against dead index entries, see ADR 0024)."}
    end
  end

  @doc """
  Parses a pgvector version such as `"0.8.7"` or `"0.10.1"` into a tuple of
  integers, compared by element (so 0.10.1 is above 0.8.7). A missing patch
  number is 0.
  """
  @spec parse_version(String.t()) :: {:ok, {integer(), integer(), integer()}} | :error
  def parse_version(version) when is_binary(version) do
    parts = version |> String.trim() |> String.split(".")

    with true <- length(parts) in 2..3,
         [major, minor, patch] <- parts |> Enum.map(&to_int/1) |> pad(),
         true <- Enum.all?([major, minor, patch], &is_integer/1) do
      {:ok, {major, minor, patch}}
    else
      _ -> :error
    end
  end

  defp pad([major, minor]), do: [major, minor, 0]
  defp pad(parts), do: parts

  defp to_int(part), do: if(part =~ ~r/\A\d+\z/, do: String.to_integer(part), else: :error)

  defp format({major, minor, patch}), do: "#{major}.#{minor}.#{patch}"
end
