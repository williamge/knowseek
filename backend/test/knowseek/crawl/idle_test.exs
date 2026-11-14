defmodule Knowseek.Crawl.IdleTest do
  use ExUnit.Case, async: true

  alias Knowseek.Crawl.Idle

  # Relies on the config defaults: idle_seconds 600, max_cpu_percent 60.
  @now ~U[2026-11-11 12:00:00Z]

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

  describe "idle?/1" do
    test "is not idle 9 minutes after a search" do
      refute Idle.idle?(now: @now, last_search_at: ago(540), cpu: 0.0)
    end

    test "is idle 10 minutes after a search" do
      assert Idle.idle?(now: @now, last_search_at: ago(600), cpu: 0.0)
    end

    test "is not idle when the CPU is 60% busy" do
      refute Idle.idle?(now: @now, last_search_at: ago(3_600), cpu: 60.0)
    end

    test "is idle when the CPU is busy under the limit" do
      assert Idle.idle?(now: @now, last_search_at: ago(3_600), cpu: 46.0)
    end

    test "is not idle when the CPU share is unknown" do
      refute Idle.idle?(now: @now, last_search_at: ago(3_600), cpu: nil)
    end

    test "is not idle on the first call, which has no previous sample" do
      refute Idle.idle?(now: @now, last_search_at: ago(3_600), cpu: :first)
    end

    test "is idle with no search at all" do
      assert Idle.idle?(now: @now, last_search_at: nil, cpu: 0.0)
    end
  end

  describe "cpu_percent/0" do
    test "is :first for a process's first call, then nil or a percentage" do
      # `cpu_sup` keeps its previous sample per calling process: use a new one.
      {first, second} =
        Task.async(fn -> {Idle.cpu_percent(), Idle.cpu_percent()} end) |> Task.await()

      assert first == :first
      assert second == nil or (is_float(second) and second >= 0.0 and second <= 100.0)
    end
  end
end
