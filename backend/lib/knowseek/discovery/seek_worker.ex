defmodule Knowseek.Discovery.SeekWorker do
  @moduledoc """
  Oban job that runs `Knowseek.Discovery.run/1` for one query.

  A job is stopped after `timeout/1` (5 minutes; Oban's default is no limit).
  The worst case of a planned job is the planner call (15 s) plus 4 queries
  with 1 search and up to 3 page fetches each (15 s per call): about 4 minutes.
  A job that hangs longer holds one of the 5 `discovery` workers, so Oban stops
  it, and a stopped job is retried like a failed one (ADR 0025).
  """
  use Oban.Worker,
    queue: :discovery,
    max_attempts: 3,
    unique: [period: 60 * 60, keys: [:query], states: :incomplete]

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"query" => query}}) do
    case Knowseek.Discovery.run(query) do
      # Every candidate failed to ingest (for example the embedding provider is
      # down): fail the job so Oban retries it. Nothing found is not a failure.
      {:ok, %{ingested: 0, failed: failed}} when failed > 0 ->
        {:error, {:all_ingests_failed, failed}}

      {:ok, _summary} ->
        :ok
    end
  end
end
