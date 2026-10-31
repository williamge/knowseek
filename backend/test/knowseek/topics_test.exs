defmodule Knowseek.TopicsTest do
  use Knowseek.DataCase, async: true

  alias Knowseek.Discovery.SeekWorker
  alias Knowseek.Topics
  alias Knowseek.Topics.{CheckWorker, RefreshWorker}

  test "follow_topic/1 validates the query" do
    assert {:error, changeset} = Topics.follow_topic(%{query: ""})
    assert %{query: ["can't be blank"]} = errors_on(changeset)
  end

  describe "follow_topic/1 uniqueness" do
    test "stores the normalized query" do
      topic = topic_fixture(query: "  Rust   Lang ")

      assert topic.query == "  Rust   Lang "
      assert topic.normalized_query == "rust lang"
    end

    test "following the same query twice gives one topic" do
      assert {:ok, first, :created} = Topics.follow_topic(%{query: "Rust"})
      assert {:ok, second, :existing} = Topics.follow_topic(%{query: "  rust "})

      assert second.id == first.id
      assert [%{id: id}] = Topics.list_topics()
      assert id == first.id
    end

    test "an existing topic is returned unchanged, whatever the new settings" do
      {:ok, first, :created} =
        Topics.follow_topic(%{query: "Rust", refresh_interval_seconds: 3600, max_age_seconds: 60})

      assert {:ok, existing, :existing} =
               Topics.follow_topic(%{
                 query: "rust",
                 refresh_interval_seconds: 604_800,
                 max_age_seconds: nil,
                 active: false
               })

      assert existing == Topics.get_topic(first.id)
      assert existing.query == "Rust"
      assert existing.refresh_interval_seconds == 3600
      assert existing.max_age_seconds == 60
      assert existing.active
    end

    test "invalid settings are still rejected for an existing query" do
      topic_fixture(query: "Rust")

      assert {:error, changeset} =
               Topics.follow_topic(%{query: "rust", refresh_interval_seconds: 1})

      assert %{refresh_interval_seconds: [_]} = errors_on(changeset)
    end

    test "simultaneous follows give one topic" do
      outcomes =
        1..8
        |> Task.async_stream(
          fn i -> Topics.follow_topic(%{query: String.duplicate(" ", i) <> "Rust"}) end,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, {:ok, topic, outcome}} -> {topic.id, outcome} end)

      assert [{id, _} | _] = outcomes
      assert Enum.all?(outcomes, fn {other, _} -> other == id end)
      assert Enum.count(outcomes, fn {_, outcome} -> outcome == :created end) == 1
      assert [_one] = Topics.list_topics()
    end

    test "the unique index rejects a duplicate that skips the changeset" do
      topic_fixture(query: "Rust")

      assert_raise Postgrex.Error, ~r/topics_normalized_query_index/, fn ->
        Repo.insert_all("topics", [
          %{
            id: Ecto.UUID.bingenerate(),
            query: "rust",
            normalized_query: "rust",
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        ])
      end
    end
  end

  test "follow_topic/1 validates max_age_seconds and refresh_interval_seconds" do
    for attrs <- [
          %{max_age_seconds: 0},
          %{max_age_seconds: 3_000_000_000},
          %{refresh_interval_seconds: 3_000_000_000}
        ] do
      assert {:error, changeset} = Topics.follow_topic(Map.put(attrs, :query, "x y"))
      [field] = Map.keys(attrs)
      assert %{^field => [_]} = errors_on(changeset)
    end
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

  describe "RefreshWorker" do
    test "enqueues one check per due topic" do
      due = topic_fixture(query: "solar flares")
      done = topic_fixture(query: "done topic")
      {:ok, _} = Topics.mark_refreshed(done)

      assert :ok = perform_job(RefreshWorker, %{})

      assert_enqueued(worker: CheckWorker, args: %{"topic_id" => due.id})
      refute_enqueued(worker: CheckWorker, args: %{"topic_id" => done.id})
      refute Topics.get_topic(due.id).last_refreshed_at
    end

    test "does not enqueue a second check while one is pending" do
      topic_fixture(query: "solar flares")

      assert :ok = perform_job(RefreshWorker, %{})
      assert :ok = perform_job(RefreshWorker, %{})

      assert [_job] = all_enqueued(worker: CheckWorker)
    end
  end

  describe "CheckWorker" do
    @refreshed_at "2026-10-30T12:00:00Z"

    test "requests discovery when the topic has no max_age_seconds" do
      for i <- 1..3, do: document_fixture(body: "Solar wind, part #{i}.")
      topic = topic_fixture(query: "solar wind")

      assert :ok = check(topic)

      assert_enqueued(worker: SeekWorker, args: %{"query" => "solar wind"})
      assert Topics.get_topic(topic.id).last_refreshed_at == ~U[2026-10-30 12:00:00Z]
    end

    test "skips discovery when the index has enough fresh documents" do
      for i <- 1..3, do: document_fixture(body: "Solar wind, part #{i}.")
      topic = topic_fixture(query: "solar wind", max_age_seconds: 3600)

      assert :ok = check(topic)

      refute_enqueued(worker: SeekWorker)
      assert Topics.get_topic(topic.id).last_refreshed_at == ~U[2026-10-30 12:00:00Z]
    end

    test "requests discovery when the topic's documents are too old" do
      old = ~U[2020-01-01 00:00:00Z]
      for i <- 1..3, do: document_fixture(body: "Solar wind, part #{i}.", fetched_at: old)
      topic = topic_fixture(query: "solar wind", max_age_seconds: 3600)

      assert :ok = check(topic)

      assert_enqueued(worker: SeekWorker, args: %{"query" => "solar wind"})
      assert Topics.get_topic(topic.id).last_refreshed_at
    end

    test "does nothing for a deleted or inactive topic" do
      deleted = topic_fixture(query: "deleted topic")
      {:ok, _} = Topics.delete_topic(deleted)
      inactive = topic_fixture(query: "inactive topic", active: false)

      assert :ok = check(deleted)
      assert :ok = check(inactive)

      refute_enqueued(worker: SeekWorker)
      refute Topics.get_topic(inactive.id).last_refreshed_at
    end

    defp check(topic),
      do: perform_job(CheckWorker, %{"topic_id" => topic.id, "refreshed_at" => @refreshed_at})
  end
end
