defmodule Knowseek.Topics.CheckWorker do
  @moduledoc """
  Checks one due topic. `Knowseek.Topics.RefreshWorker` enqueues it.

    * Without `max_age_seconds`, the topic requests discovery.
    * With `max_age_seconds`, the job runs a `Knowseek.Lookup` with that
      freshness need, so discovery runs only when the index has too few
      fresh documents for the topic.

  On success, the topic is marked refreshed at `refreshed_at`, the time of
  the cron run. On failure, the job retries. The topic stays due, and the
  unique option stops the cron from enqueuing a second job meanwhile.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, keys: [:topic_id], states: :incomplete]

  alias Knowseek.{Discovery, Lookup, Topics}
  alias Knowseek.Topics.Topic

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"topic_id" => id, "refreshed_at" => refreshed_at}}) do
    {:ok, refreshed_at, _offset} = DateTime.from_iso8601(refreshed_at)

    case Topics.get_topic(id) do
      # Deleted or paused after the job was enqueued.
      nil ->
        :ok

      %Topic{active: false} ->
        :ok

      topic ->
        with :ok <- check(topic),
             {:ok, _topic} <- Topics.mark_refreshed(topic, refreshed_at) do
          :ok
        end
    end
  end

  defp check(%Topic{max_age_seconds: nil} = topic) do
    case Discovery.request(topic.query) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp check(%Topic{} = topic) do
    case Lookup.run(topic.query, max_age_seconds: topic.max_age_seconds) do
      {:ok, %{discovery: {:error, reason}}} -> {:error, reason}
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
