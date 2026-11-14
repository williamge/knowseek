defmodule Knowseek.Documents.ReembedWorker do
  @moduledoc """
  Oban job that re-embeds the next pages whose vectors come from another
  model (`Knowseek.Documents.reembed_stale/1`) and, while some are left,
  enqueues itself again (#84, #53, ADR 0035). A failed embedding fails the
  job; Oban retries it, and `Knowseek.Documents.ModelWatch` enqueues a new one
  when the retries are used up.
  """
  use Oban.Worker,
    queue: :index,
    max_attempts: 5,
    # Not :executing: the running job must be able to enqueue the next one,
    # and a job orphaned by a crash must not block a new one.
    unique: [period: :infinity, fields: [:worker], states: [:available, :scheduled, :retryable]]

  alias Knowseek.{Documents, Repo}

  @doc "Enqueues the job unless one is waiting. Safe to call at any time."
  @spec enqueue() :: :ok
  def enqueue do
    # The transaction makes the uniqueness check safe on the Lite engine, as in
    # `Knowseek.Discovery.request/1`.
    {:ok, _job} = Repo.transact(fn -> Oban.insert(new(%{})) end)
    :ok
  end

  @impl Oban.Worker
  def perform(_job) do
    case Documents.reembed_stale() do
      {:ok, %{more?: true}} -> enqueue()
      {:ok, %{more?: false}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
