defmodule Knowseek.Documents.ModelWatch do
  @moduledoc """
  A supervised timer: it asks the embedding provider which model it serves
  and, when pages have vectors of another model, enqueues the re-embed job
  (`Knowseek.Documents.check_model/0`, #84, ADR 0035). It checks right after
  the start and then every `check_ms`, so an `ollama pull` while the app runs
  is noticed within a minute. It only reads and enqueues (rule 6 of
  `AGENTS.md`); `Knowseek.Crawl.Scheduler` is its precedent.

  It keeps one piece of state, the last result (`:current`, `:reembedding` or
  `{:error, reason}`), and logs only when that changes.

  Options: `:name` (default the module), `:check_ms` (default from the
  `Knowseek.Documents.Reembed` config; `:manual` sets no timer, and a test
  sends `:tick`) and `:check` (a function; default
  `&Knowseek.Documents.check_model/0`).
  """
  use GenServer

  require Logger

  alias Knowseek.Documents

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    state = %{
      check_ms: Keyword.get_lazy(opts, :check_ms, fn -> config()[:check_ms] end),
      check: Keyword.get(opts, :check, &Documents.check_model/0),
      last: nil
    }

    # Returns at once: the first check never delays the start.
    unless state.check_ms == :manual, do: send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    result = run_check(state.check)
    log_change(state.last, result)
    schedule(state.check_ms)
    {:noreply, %{state | last: result}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A missing table or a busy database must not restart the supervisor.
  defp run_check(check) do
    check.()
  rescue
    exception ->
      Logger.warning("embedding model check failed: #{Exception.message(exception)}")
      {:error, {:exception, exception}}
  end

  defp log_change(same, same), do: :ok

  defp log_change(_previous, :reembedding), do: Logger.info(reembedding_message())

  defp log_change(:reembedding, :current), do: Logger.info("re-embedding finished")

  defp log_change(_previous, {:error, {:exception, _}}), do: :ok

  defp log_change(_previous, {:error, reason}),
    do: Logger.warning("cannot ask the embedding provider for its model: #{inspect(reason)}")

  defp log_change(_previous, :current), do: :ok

  defp reembedding_message do
    case Documents.index_status() do
      %{model: %{name: name, digest: digest}, passages: total, current_passages: current} ->
        digest = if digest == "", do: "", else: " (#{String.slice(digest, 0, 7)})"

        "embedding model #{name}#{digest}: #{delimit(current)} of #{delimit(total)} passages " <>
          "have this model's vectors; re-embedding the rest in the background"

      _ ->
        "re-embedding the index in the background"
    end
  rescue
    _ -> "re-embedding the index in the background"
  end

  defp delimit(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp schedule(:manual), do: :ok
  defp schedule(check_ms), do: Process.send_after(self(), :tick, check_ms)

  defp config, do: Application.fetch_env!(:knowseek, Knowseek.Documents.Reembed)
end
