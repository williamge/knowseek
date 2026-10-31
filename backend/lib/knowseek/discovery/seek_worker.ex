defmodule Knowseek.Discovery.SeekWorker do
  @moduledoc "Oban job that runs `Knowseek.Discovery.run/1` for one query."
  use Oban.Worker,
    queue: :discovery,
    max_attempts: 3,
    unique: [period: 60 * 60, keys: [:query], states: :incomplete]

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
