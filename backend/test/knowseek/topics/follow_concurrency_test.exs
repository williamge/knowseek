defmodule Knowseek.Topics.FollowConcurrencyTest do
  # Real concurrency needs one database connection per process, so this test
  # leaves the sandbox: it commits rows and deletes them in `on_exit`. It runs
  # after the async modules (async: false), so nothing else sees them.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Knowseek.Repo
  alias Knowseek.Topics
  alias Knowseek.Topics.Topic

  setup do
    Sandbox.mode(Repo, :auto)
    Repo.delete_all(Topic)

    on_exit(fn ->
      Repo.delete_all(Topic)
      Sandbox.mode(Repo, :manual)
    end)
  end

  test "simultaneous follows of one query give one topic" do
    count = 8
    parent = self()

    tasks =
      for i <- 1..count do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> :ok)
          Topics.follow_topic(%{query: String.duplicate(" ", i) <> "Rust"})
        end)
      end

    for _ <- 1..count, do: assert_receive({:ready, _pid}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))

    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert Enum.all?(results, &match?({:ok, %Topic{}, _}, &1))
    assert [id] = results |> Enum.map(fn {:ok, topic, _} -> topic.id end) |> Enum.uniq()
    assert Enum.count(results, &match?({:ok, _, :created}, &1)) == 1
    assert Enum.count(results, &match?({:ok, _, :existing}, &1)) == count - 1
    assert [%Topic{id: ^id}] = Repo.all(Topic)
  end
end
