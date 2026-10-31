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

  Must not be called inside `Repo.transaction/1` or an `Ecto.Multi`: the
  insert that hits the unique index aborts the surrounding transaction.
  """
  @spec follow_topic(map()) ::
          {:ok, Topic.t(), :created | :existing} | {:error, Ecto.Changeset.t()}
  def follow_topic(attrs), do: follow_topic(attrs, 1)

  defp follow_topic(attrs, retries) do
    changeset = Topic.changeset(%Topic{}, attrs)

    case Repo.insert(changeset) do
      {:ok, topic} ->
        {:ok, topic, :created}

      {:error, %Ecto.Changeset{} = failed} ->
        resolve_conflict(failed, attrs, retries)
    end
  end

  # A unique conflict means the topic exists: return it. If it was unfollowed
  # between the failed insert and the read, insert again, once.
  defp resolve_conflict(failed, attrs, retries) do
    if Keyword.has_key?(failed.errors, :normalized_query) do
      case get_by_normalized_query(Ecto.Changeset.get_change(failed, :normalized_query)) do
        %Topic{} = topic -> {:ok, topic, :existing}
        nil when retries > 0 -> follow_topic(attrs, retries - 1)
        nil -> {:error, failed}
      end
    else
      {:error, failed}
    end
  end

  # The md5 condition lets Postgres use the unique index; the equality makes
  # the match exact.
  defp get_by_normalized_query(normalized) do
    Repo.one(
      from t in Topic,
        where: fragment("md5(?)", t.normalized_query) == fragment("md5(?)", ^normalized),
        where: t.normalized_query == ^normalized
    )
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
