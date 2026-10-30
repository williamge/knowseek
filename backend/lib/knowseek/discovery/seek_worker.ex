defmodule Knowseek.Discovery.SeekWorker do
  @moduledoc "Oban job that runs `Knowseek.Discovery.run/1` for one query."
  use Oban.Worker,
    queue: :discovery,
    max_attempts: 3,
    unique: [period: 60 * 60, keys: [:query], states: :incomplete]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"query" => query}}) do
    {:ok, _summary} = Knowseek.Discovery.run(query)
    :ok
  end
end
