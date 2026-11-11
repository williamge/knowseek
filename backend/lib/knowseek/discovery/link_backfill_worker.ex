defmodule Knowseek.Discovery.LinkBackfillWorker do
  @moduledoc "Oban job that logs the blocked links of one already indexed document (`Knowseek.Discovery.fetch_links/1`). The one-off backfill of #88."
  use Oban.Worker,
    queue: :discovery,
    max_attempts: 3,
    priority: 3,
    unique: [period: :infinity, keys: [:document_id], states: :incomplete]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => id}}), do: Knowseek.Discovery.fetch_links(id)
end
