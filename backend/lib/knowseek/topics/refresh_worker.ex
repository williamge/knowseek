defmodule Knowseek.Topics.RefreshWorker do
  @moduledoc "Cron job. Requests discovery for every topic that is due."
  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias Knowseek.{Discovery, Topics}

  @impl Oban.Worker
  def perform(_job) do
    # One timestamp for the whole run. A per-topic timestamp drifts past the
    # next cron tick and can delay a topic by a full cron period.
    now = DateTime.utc_now()

    for topic <- Topics.due_topics(now) do
      case Discovery.request(topic.query) do
        {:ok, _job} ->
          {:ok, _topic} = Topics.mark_refreshed(topic, now)

        {:error, reason} ->
          # Leave the topic due so the next run retries it.
          Logger.warning("topic refresh failed for #{topic.id}: #{inspect(reason)}")
      end
    end

    :ok
  end
end
