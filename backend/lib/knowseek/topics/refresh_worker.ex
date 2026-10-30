defmodule Knowseek.Topics.RefreshWorker do
  @moduledoc """
  Cron job. Enqueues one `Knowseek.Topics.CheckWorker` job for every topic
  that is due. The check jobs do the slow work, so one failing topic does
  not stop the others.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias Knowseek.Topics
  alias Knowseek.Topics.CheckWorker

  @impl Oban.Worker
  def perform(_job) do
    # One timestamp for the whole run. A per-topic timestamp drifts past the
    # next cron tick and can delay a topic by a full cron period.
    now = DateTime.utc_now()

    for topic <- Topics.due_topics(now) do
      case CheckWorker.new(%{"topic_id" => topic.id, "refreshed_at" => DateTime.to_iso8601(now)})
           |> Oban.insert() do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          # The topic stays due, so the next run retries it.
          Logger.warning("topic check enqueue failed for #{topic.id}: #{inspect(reason)}")
      end
    end

    :ok
  end
end
