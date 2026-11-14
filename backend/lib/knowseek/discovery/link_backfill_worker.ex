defmodule Knowseek.Discovery.LinkBackfillWorker do
  @moduledoc """
  Oban job that logs the blocked links of one already indexed document
  (`Knowseek.Discovery.fetch_links/1`). The one-off backfill of #88. It waits
  a day (`{:snooze, 86_400}`) while background work is held back by a budget
  (#90, ADR 0034).
  """
  use Oban.Worker,
    queue: :discovery,
    max_attempts: 3,
    priority: 3,
    unique: [period: :infinity, keys: [:document_id], states: :incomplete]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => id}}) do
    # A fixed wait, not "until midnight": every waiting job moves by the same
    # 24 hours, so the two-a-second pace of `Discovery.backfill_links/0` holds
    # (ADR 0032).
    case Knowseek.Activity.hold(:background) do
      nil -> Knowseek.Discovery.fetch_links(id)
      _reason -> {:snooze, 86_400}
    end
  end
end
