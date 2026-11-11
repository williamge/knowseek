defmodule Knowseek.Crawl.SchedulerTest do
  use Knowseek.DataCase, async: false

  alias Knowseek.Crawl.{Scheduler, Worker}

  defp start_scheduler(due) do
    name = :"crawl_scheduler_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Scheduler, name: name, tick_ms: :manual, due: due})
    pid
  end

  describe "tick" do
    test "enqueues one worker job when due, and not a second" do
      pid = start_scheduler(fn -> true end)

      send(pid, :tick)
      _ = :sys.get_state(pid)
      assert_enqueued(worker: Worker)

      send(pid, :tick)
      _ = :sys.get_state(pid)
      assert [_one] = all_enqueued(worker: Worker)
    end

    test "enqueues nothing when not due" do
      pid = start_scheduler(fn -> false end)

      send(pid, :tick)
      _ = :sys.get_state(pid)

      refute_enqueued(worker: Worker)
    end

    test "ignores other messages" do
      pid = start_scheduler(fn -> true end)

      send(pid, :something_else)
      _ = :sys.get_state(pid)

      refute_enqueued(worker: Worker)
    end
  end

  describe "Worker" do
    test "perform runs a step (nothing to do with the mode off)" do
      assert :ok = perform_job(Worker, %{})
    end
  end
end
