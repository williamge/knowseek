defmodule Knowseek.Crawl.Scheduler do
  @moduledoc """
  A supervised timer: once a minute it checks whether the background crawl is
  due (`Knowseek.Crawl.due?/1`) and, if so, enqueues one
  `Knowseek.Crawl.Worker` job (#89, ADR 0033). It only reads and enqueues
  (rule 6 of `AGENTS.md`), and holds no other state.

  Not Oban's cron plugin: that would insert a job row every minute, 1,440 a
  day, for a check that is almost always "no".

  Options: `:name` (default the module), `:tick_ms` (default from the
  `Knowseek.Crawl` config; `:manual` sets no timer, for tests) and `:due` (a
  function; default `&Knowseek.Crawl.due?/0`).
  """
  use GenServer

  alias Knowseek.Crawl.Worker
  alias Knowseek.Repo

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    state = %{
      tick_ms: Keyword.get_lazy(opts, :tick_ms, fn -> config()[:tick_ms] end),
      due: Keyword.get(opts, :due, &Knowseek.Crawl.due?/0)
    }

    schedule(state.tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    if state.due.() do
      # The transaction is what makes the uniqueness check safe on the Lite
      # engine (as in `Knowseek.Discovery.request/1`).
      {:ok, _job} = Repo.transact(fn -> Oban.insert(Worker.new(%{})) end)
    end

    schedule(state.tick_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(:manual), do: :ok
  defp schedule(tick_ms), do: Process.send_after(self(), :tick, tick_ms)

  defp config, do: Application.fetch_env!(:knowseek, Knowseek.Crawl)
end
