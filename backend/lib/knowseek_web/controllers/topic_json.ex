defmodule KnowseekWeb.TopicJSON do
  alias Knowseek.Topics.Topic

  def index(%{topics: topics}), do: %{data: Enum.map(topics, &data/1)}

  def show(%{topic: topic}), do: %{data: data(topic)}

  defp data(%Topic{} = topic) do
    %{
      id: topic.id,
      query: topic.query,
      active: topic.active,
      refresh_interval_seconds: topic.refresh_interval_seconds,
      last_refreshed_at: topic.last_refreshed_at,
      inserted_at: topic.inserted_at
    }
  end
end
