defmodule Knowseek.TopicsTest do
  use Knowseek.DataCase, async: true

  alias Knowseek.Discovery.SeekWorker
  alias Knowseek.Topics
  alias Knowseek.Topics.RefreshWorker

  test "create_topic/1 validates the query" do
    assert {:error, changeset} = Topics.create_topic(%{query: ""})
    assert %{query: ["can't be blank"]} = errors_on(changeset)
  end

  describe "due_topics/1" do
    test "includes new topics and topics past their interval" do
      now = ~U[2026-01-01 12:00:00Z]
      new = topic_fixture(query: "new topic")
      stale = topic_fixture(query: "stale topic", refresh_interval_seconds: 3600)
      fresh = topic_fixture(query: "fresh topic", refresh_interval_seconds: 3600)
      inactive = topic_fixture(query: "inactive topic", active: false)

      {:ok, _} = Topics.mark_refreshed(stale, DateTime.add(now, -2, :hour))
      {:ok, _} = Topics.mark_refreshed(fresh, DateTime.add(now, -10, :minute))

      due_ids = now |> Topics.due_topics() |> Enum.map(& &1.id) |> MapSet.new()

      assert due_ids == MapSet.new([new.id, stale.id])
      refute inactive.id in due_ids
    end
  end

  test "RefreshWorker requests discovery for due topics and marks them refreshed" do
    topic = topic_fixture(query: "solar flares")

    assert :ok = perform_job(RefreshWorker, %{})

    assert_enqueued(worker: SeekWorker, args: %{"query" => "solar flares"})
    assert Topics.get_topic(topic.id).last_refreshed_at
  end
end
