defmodule KnowseekWeb.TopicController do
  use KnowseekWeb, :controller

  alias Knowseek.Topics

  action_fallback KnowseekWeb.FallbackController

  def index(conn, _params) do
    render(conn, :index, topics: Topics.list_topics())
  end

  def show(conn, %{"id" => id}) do
    with %{} = topic <- Topics.get_topic(id) do
      render(conn, :show, topic: topic)
    end
  end

  def create(conn, %{"topic" => params}) do
    with {:ok, topic} <- Topics.create_topic(params) do
      conn
      |> put_status(:created)
      |> render(:show, topic: topic)
    end
  end

  def create(_conn, _params), do: {:error, {:bad_request, "topic is required"}}

  def delete(conn, %{"id" => id}) do
    with %{} = topic <- Topics.get_topic(id),
         {:ok, _topic} <- Topics.delete_topic(topic) do
      send_resp(conn, :no_content, "")
    end
  end
end
