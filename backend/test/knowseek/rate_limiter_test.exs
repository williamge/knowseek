defmodule Knowseek.RateLimiterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Knowseek.RateLimiter

  setup do
    clock = start_supervised!({Agent, fn -> 1_000_000 end})
    {:ok, clock: clock, limiter: start_limiter(clock)}
  end

  defp start_limiter(clock, opts \\ []) do
    name = :"limiter_#{System.unique_integer([:positive])}"

    start_supervised!(
      {RateLimiter,
       [name: name, clock: fn -> Agent.get(clock, & &1) end, sweep_interval: :infinity] ++ opts},
      id: name
    )

    name
  end

  defp advance(clock, ms), do: Agent.update(clock, &(&1 + ms))

  describe "hit/4" do
    test "allows a burst of `limit`, then denies", %{limiter: limiter} do
      for _ <- 1..3, do: assert(RateLimiter.hit(limiter, :a, 3, 3_000) == :ok)
      assert RateLimiter.hit(limiter, :a, 3, 3_000) == {:error, 1_000}
    end

    test "refills `limit` tokens per window", %{limiter: limiter, clock: clock} do
      for _ <- 1..3, do: :ok = RateLimiter.hit(limiter, :a, 3, 3_000)

      advance(clock, 999)
      assert RateLimiter.hit(limiter, :a, 3, 3_000) == {:error, 1}
      advance(clock, 1)
      assert RateLimiter.hit(limiter, :a, 3, 3_000) == :ok
      assert RateLimiter.hit(limiter, :a, 3, 3_000) == {:error, 1_000}

      # A client that keeps asking settles at the rate: one request a second.
      for _ <- 1..10 do
        advance(clock, 1_000)
        assert RateLimiter.hit(limiter, :a, 3, 3_000) == :ok
        assert {:error, _} = RateLimiter.hit(limiter, :a, 3, 3_000)
      end
    end

    test "never holds more than `limit` tokens, however long the client was away", %{
      limiter: limiter,
      clock: clock
    } do
      :ok = RateLimiter.hit(limiter, :a, 3, 3_000)
      advance(clock, 3_600_000)

      for _ <- 1..3, do: assert(RateLimiter.hit(limiter, :a, 3, 3_000) == :ok)
      assert {:error, _} = RateLimiter.hit(limiter, :a, 3, 3_000)
    end

    test "a denied hit takes nothing, so the wait does not grow", %{
      limiter: limiter,
      clock: clock
    } do
      for _ <- 1..2, do: :ok = RateLimiter.hit(limiter, :a, 2, 1_000)

      for _ <- 1..50, do: assert(RateLimiter.hit(limiter, :a, 2, 1_000) == {:error, 500})

      advance(clock, 500)
      assert RateLimiter.hit(limiter, :a, 2, 1_000) == :ok
    end

    test "the wait is the time until the next token, rounded up", %{
      limiter: limiter,
      clock: clock
    } do
      for _ <- 1..3, do: :ok = RateLimiter.hit(limiter, :a, 3, 1_000)
      # One token every 333.33 ms.
      assert RateLimiter.hit(limiter, :a, 3, 1_000) == {:error, 334}

      advance(clock, 100)
      assert RateLimiter.hit(limiter, :a, 3, 1_000) == {:error, 234}
    end

    test "keys are independent", %{limiter: limiter} do
      for _ <- 1..2, do: :ok = RateLimiter.hit(limiter, {:search, :client_a}, 2, 60_000)
      assert {:error, _} = RateLimiter.hit(limiter, {:search, :client_a}, 2, 60_000)

      assert RateLimiter.hit(limiter, {:search, :client_b}, 2, 60_000) == :ok
      assert RateLimiter.hit(limiter, {:cards, :client_a}, 2, 60_000) == :ok
    end

    test "returns :ok and logs when the limiter is not running" do
      log =
        capture_log(fn ->
          assert RateLimiter.hit(:no_such_limiter, :a, 1, 1_000) == :ok
        end)

      assert log =~ "rate limiter unreachable"
    end
  end

  test "the application runs one, with the limits of the configuration" do
    assert is_pid(Process.whereis(RateLimiter))

    limits = Application.fetch_env!(:knowseek, KnowseekWeb.RateLimit)[:limits]
    assert Enum.sort(Keyword.keys(limits)) == [:cards, :documents, :search]

    for {_bucket, {limit, window_ms}} <- limits do
      assert is_integer(limit) and limit > 0
      assert is_integer(window_ms) and window_ms > 0
    end
  end

  describe "memory" do
    test "keeps at most max_buckets, however many keys arrive", %{clock: clock} do
      limiter = start_limiter(clock, max_buckets: 20)

      for n <- 1..1_000 do
        advance(clock, 1)
        :ok = RateLimiter.hit(limiter, {:junk, n}, 5, 60_000)
        assert RateLimiter.size(limiter) <= 20
      end
    end

    test "full buckets go first: nothing that still counts is lost", %{clock: clock} do
      limiter = start_limiter(clock, max_buckets: 4)

      # Two clients that used their tokens up and stay over their limit ...
      for key <- [:a, :b], _ <- 1..2, do: :ok = RateLimiter.hit(limiter, key, 2, 60_000)
      # ... and two that have refilled completely by the time the cap is reached.
      for key <- [:c, :d], do: :ok = RateLimiter.hit(limiter, key, 1, 1_000)
      advance(clock, 1_000)

      :ok = RateLimiter.hit(limiter, :e, 2, 60_000)

      assert RateLimiter.size(limiter) == 3
      assert {:error, _} = RateLimiter.hit(limiter, :a, 2, 60_000)
      assert {:error, _} = RateLimiter.hit(limiter, :b, 2, 60_000)
    end

    test "a flood of new keys evicts the least recently used, not the active client", %{
      clock: clock
    } do
      limiter = start_limiter(clock, max_buckets: 10)

      for n <- 1..200 do
        advance(clock, 1)
        # An active client that is over its limit stays over it.
        RateLimiter.hit(limiter, :active, 2, 3_600_000)
        :ok = RateLimiter.hit(limiter, {:junk, n}, 2, 3_600_000)
      end

      assert RateLimiter.size(limiter) <= 10
      assert {:error, _} = RateLimiter.hit(limiter, :active, 2, 3_600_000)
    end

    test "sweep/1 drops the buckets that have refilled, and only those", %{
      limiter: limiter,
      clock: clock
    } do
      :ok = RateLimiter.hit(limiter, :fast, 1, 1_000)
      :ok = RateLimiter.hit(limiter, :slow, 1, 60_000)
      assert RateLimiter.size(limiter) == 2

      advance(clock, 999)
      assert RateLimiter.sweep(limiter) == 0

      advance(clock, 1)
      assert RateLimiter.sweep(limiter) == 1
      assert RateLimiter.size(limiter) == 1
      assert {:error, _} = RateLimiter.hit(limiter, :slow, 1, 60_000)
    end

    test "the sweep runs on a timer", %{clock: clock} do
      limiter = start_limiter(clock, sweep_interval: 60_000)
      :ok = RateLimiter.hit(limiter, :a, 1, 1_000)
      advance(clock, 1_000)

      send(limiter, :sweep)
      assert RateLimiter.size(limiter) == 0
    end
  end
end
