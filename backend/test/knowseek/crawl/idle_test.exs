defmodule Knowseek.Crawl.IdleTest do
  use ExUnit.Case, async: true

  alias Knowseek.Crawl.Idle

  # Relies on the config defaults: idle_seconds 600, max_load 0.5.
  @now ~U[2026-11-11 12:00:00Z]

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

  describe "idle?/1" do
    test "is not idle 9 minutes after a search" do
      refute Idle.idle?(now: @now, last_search_at: ago(540), load: 0.0)
    end

    test "is idle 10 minutes after a search" do
      assert Idle.idle?(now: @now, last_search_at: ago(600), load: 0.0)
    end

    test "is not idle at a load of 0.5" do
      refute Idle.idle?(now: @now, last_search_at: ago(3_600), load: 0.5)
    end

    test "is idle under the load limit" do
      assert Idle.idle?(now: @now, last_search_at: ago(3_600), load: 0.49)
    end

    test "is not idle when the load is unknown" do
      refute Idle.idle?(now: @now, last_search_at: ago(3_600), load: nil)
    end

    test "is idle with no search at all" do
      assert Idle.idle?(now: @now, last_search_at: nil, load: 0.0)
    end
  end

  describe "load_per_core/0" do
    test "is nil or a non-negative float" do
      load = Idle.load_per_core()
      assert load == nil or load >= 0.0
    end
  end
end
