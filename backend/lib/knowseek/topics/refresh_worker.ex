defmodule Knowseek.Topics.RefreshWorker do
  @moduledoc "Cron job. Requests discovery for every topic that is due."
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Knowseek.{Discovery, Topics}

  @impl Oban.Worker
  def perform(_job) do
    for topic <- Topics.due_topics() do
      {:ok, _job} = Discovery.request(topic.query)
      {:ok, _topic} = Topics.mark_refreshed(topic)
    end

    :ok
  end
end
