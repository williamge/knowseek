defmodule Knowseek.Topics do
  @moduledoc """
  Topics a user wants to stay informed about.

  `Knowseek.Topics.RefreshWorker` runs on a cron schedule and requests
  discovery for every topic that is due.
  """
  import Ecto.Query

  alias Knowseek.Repo
  alias Knowseek.Topics.Topic

  @spec list_topics() :: [Topic.t()]
  def list_topics, do: Repo.all(from t in Topic, order_by: [asc: t.inserted_at])

  @spec get_topic(Ecto.UUID.t()) :: Topic.t() | nil
  def get_topic(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Topic, uuid)
      :error -> nil
    end
  end

  @doc """
  Follows a query. Topics are unique by normalized query
  (`Knowseek.Discovery.normalize/1`).

  Returns `{:ok, topic, :created}` for a new topic. When the query is already
  followed, returns `{:ok, topic, :existing}` with the stored topic,
  unchanged: the settings in `attrs` are ignored. The unique index decides, so
  two simultaneous follows of one query also give one topic.
  """
  @spec follow_topic(map()) ::
          {:ok, Topic.t(), :created | :existing} | {:error, Ecto.Changeset.t()}
  def follow_topic(attrs) do
    changeset = Topic.changeset(%Topic{}, attrs)

    case Repo.insert(changeset) do
      {:ok, topic} ->
        {:ok, topic, :created}

      {:error, %Ecto.Changeset{} = failed} ->
        with true <- Keyword.has_key?(failed.errors, :normalized_query),
             %Topic{} = topic <-
               Repo.get_by(Topic,
                 normalized_query: Ecto.Changeset.get_change(failed, :normalized_query)
               ) do
          {:ok, topic, :existing}
        else
          # Unique conflict, but the topic was unfollowed before we read it: insert again.
          nil -> follow_topic(attrs)
          false -> {:error, failed}
        end
    end
  end

  @spec delete_topic(Topic.t()) :: {:ok, Topic.t()} | {:error, Ecto.Changeset.t()}
  def delete_topic(%Topic{} = topic), do: Repo.delete(topic)

  @doc "Active topics that were never refreshed, or whose interval has passed."
  @spec due_topics(DateTime.t()) :: [Topic.t()]
  def due_topics(now \\ DateTime.utc_now()) do
    Repo.all(
      from t in Topic,
        where: t.active,
        where:
          is_nil(t.last_refreshed_at) or
            fragment(
              "? + make_interval(secs => ?) <= ?",
              t.last_refreshed_at,
              t.refresh_interval_seconds,
              ^now
            )
    )
  end

  @spec mark_refreshed(Topic.t(), DateTime.t()) :: {:ok, Topic.t()}
  def mark_refreshed(%Topic{} = topic, now \\ DateTime.utc_now()) do
    topic
    |> Ecto.Changeset.change(last_refreshed_at: DateTime.truncate(now, :second))
    |> Repo.update()
  end
end
