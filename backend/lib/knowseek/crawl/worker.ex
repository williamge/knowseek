defmodule Knowseek.Crawl.Worker do
  @moduledoc "Oban job that does one step of the background crawl (`Knowseek.Crawl.step/1`). A failed step is not retried: the scheduler's next tick is the retry."
  use Oban.Worker,
    queue: :crawl,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: Knowseek.Crawl.step()
end
