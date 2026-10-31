defmodule Knowseek.CacheTest do
  use ExUnit.Case, async: true

  alias Knowseek.Cache

  @start_ms 1_800_000_000_000

  setup do
    clock = start_supervised!({Agent, fn -> @start_ms end})
    name = :"cache_#{System.unique_integer([:positive])}"

    start_supervised!({Cache, name: name, clock: fn -> Agent.get(clock, & &1) end})

    {:ok, cache: name, clock: clock}
  end

  defp advance(clock, ms), do: Agent.update(clock, &(&1 + ms))

  defp as_of(ms), do: DateTime.from_unix!(ms, :millisecond)

  # A fetch that reports itself to the test and returns `result`.
  defp fetcher(result) do
    test = self()

    fn ->
      send(test, {:fetching, self()})
      result
    end
  end

  # A fetch that waits for the test to release it.
  defp blocked_fetcher(result) do
    test = self()

    fn ->
      send(test, {:fetching, self()})

      receive do
        :release -> result
      end
    end
  end

  # Fills `key` and waits for the fetch to be stored.
  defp fill(cache, key, result, opts \\ []) do
    Cache.get(cache, key, fetcher(result), opts)
    :ok = Cache.await(cache, key)
    assert_receive {:fetching, _}
  end

  describe "get/4" do
    test "a cold key returns :pending at once and fetches in another process", %{cache: cache} do
      assert Cache.get(cache, :k, blocked_fetcher({:ok, 1})) == :pending

      assert_receive {:fetching, fetch_pid}
      assert fetch_pid != self()

      # The fetch is still running: the caller was not blocked on it.
      assert Cache.get(cache, :k, blocked_fetcher({:ok, 2})) == :pending

      send(fetch_pid, :release)
      :ok = Cache.await(cache, :k)

      assert {:fresh, 1, as_of} = Cache.get(cache, :k, fetcher({:ok, 3}))
      assert as_of == as_of(@start_ms)
      refute_receive {:fetching, _}, 20
    end

    test "many concurrent callers cost one fetch (single-flight)", %{cache: cache} do
      fetch = blocked_fetcher({:ok, :v})

      results =
        1..30
        |> Task.async_stream(fn _ -> Cache.get(cache, :k, fetch) end, max_concurrency: 30)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &(&1 == :pending))

      assert_receive {:fetching, fetch_pid}
      # Every refresh request has reached the cache process once this returns.
      _ = :sys.get_state(cache)
      refute_receive {:fetching, _}, 20

      send(fetch_pid, :release)
      :ok = Cache.await(cache, :k)

      assert {:fresh, :v, _as_of} = Cache.get(cache, :k, fetcher({:ok, :other}))
      refute_receive {:fetching, _}, 20
    end

    test "a fresh value is returned without a fetch until its TTL ends", %{
      cache: cache,
      clock: clock
    } do
      fill(cache, :k, {:ok, :v}, ttl: 1_000)

      advance(clock, 999)
      assert {:fresh, :v, _as_of} = Cache.get(cache, :k, fetcher({:ok, :new}))
      refute_receive {:fetching, _}, 20

      advance(clock, 1)
      assert {:stale, :v, as_of} = Cache.get(cache, :k, fetcher({:ok, :new}))
      assert as_of == as_of(@start_ms)
    end

    test "an expired value is served stale while it refreshes", %{cache: cache, clock: clock} do
      fill(cache, :k, {:ok, :old}, ttl: 1_000)
      advance(clock, 5_000)

      assert {:stale, :old, _as_of} = Cache.get(cache, :k, blocked_fetcher({:ok, :new}))
      assert_receive {:fetching, fetch_pid}

      # Single-flight also holds for a refresh.
      assert {:stale, :old, _as_of} = Cache.get(cache, :k, blocked_fetcher({:ok, :newer}))
      _ = :sys.get_state(cache)
      refute_receive {:fetching, _}, 20

      send(fetch_pid, :release)
      :ok = Cache.await(cache, :k)

      assert {:fresh, :new, as_of} = Cache.get(cache, :k, fetcher({:ok, :newest}))
      assert as_of == as_of(@start_ms + 5_000)
    end

    test "the TTL can depend on the fetched value", %{cache: cache, clock: clock} do
      ttl = fn
        :live -> 10
        :final -> 10_000
      end

      fill(cache, :live, {:ok, :live}, ttl: ttl)
      fill(cache, :final, {:ok, :final}, ttl: ttl)

      advance(clock, 11)
      assert {:stale, :live, _as_of} = Cache.get(cache, :live, fetcher({:ok, :live}))
      assert {:fresh, :final, _as_of} = Cache.get(cache, :final, fetcher({:ok, :final}))
    end

    test "any value is cached, including nil and :none", %{cache: cache} do
      fill(cache, :nil_value, {:ok, nil})
      fill(cache, :none_value, {:ok, :none})

      assert {:fresh, nil, _as_of} = Cache.get(cache, :nil_value, fetcher({:ok, 1}))
      assert {:fresh, :none, _as_of} = Cache.get(cache, :none_value, fetcher({:ok, 1}))
      refute_receive {:fetching, _}, 20
    end
  end

  describe "failures" do
    test "a failed refresh keeps the old value, and a backoff stops new fetches", %{
      cache: cache,
      clock: clock
    } do
      fill(cache, :k, {:ok, :old}, ttl: 1_000)
      advance(clock, 2_000)

      assert {:stale, :old, _as_of} =
               Cache.get(cache, :k, fetcher({:error, :boom}), backoff: 500)

      assert_receive {:fetching, _}
      :ok = Cache.await(cache, :k)

      # The old value stays. No fetch starts during the backoff.
      advance(clock, 499)
      assert {:stale, :old, as_of} = Cache.get(cache, :k, fetcher({:ok, :new}))
      assert as_of == as_of(@start_ms)
      _ = :sys.get_state(cache)
      refute_receive {:fetching, _}, 20

      # After it, the next call fetches again.
      advance(clock, 1)
      assert {:stale, :old, _as_of} = Cache.get(cache, :k, fetcher({:ok, :new}))
      assert_receive {:fetching, _}
      :ok = Cache.await(cache, :k)

      assert {:fresh, :new, _as_of} = Cache.get(cache, :k, fetcher({:ok, :newer}))
    end

    test "with nothing cached, a failure is :unavailable until the backoff ends", %{
      cache: cache,
      clock: clock
    } do
      assert Cache.get(cache, :k, fetcher({:error, :boom}), backoff: 500) == :pending
      assert_receive {:fetching, _}
      :ok = Cache.await(cache, :k)

      assert Cache.get(cache, :k, fetcher({:ok, 1})) == {:unavailable, :boom}
      _ = :sys.get_state(cache)
      refute_receive {:fetching, _}, 20

      advance(clock, 500)
      assert Cache.get(cache, :k, fetcher({:ok, 1})) == {:unavailable, :boom}
      assert_receive {:fetching, _}
      :ok = Cache.await(cache, :k)

      assert {:fresh, 1, _as_of} = Cache.get(cache, :k, fetcher({:ok, 2}))
    end

    test "a crashing fetch is a failure and the cache survives", %{cache: cache} do
      pid = Process.whereis(cache)

      assert Cache.get(cache, :k, fn -> raise "boom" end) == :pending
      :ok = Cache.await(cache, :k)

      assert {:unavailable, {:exit, {%RuntimeError{message: "boom"}, _stacktrace}}} =
               Cache.get(cache, :k, fetcher({:ok, 1}))

      assert Process.whereis(cache) == pid
    end

    test "a fetch that returns neither ok nor error is a failure", %{cache: cache} do
      Cache.get(cache, :k, fn -> :oops end)
      :ok = Cache.await(cache, :k)

      assert Cache.get(cache, :k, fetcher({:ok, 1})) == {:unavailable, {:bad_return, :oops}}
    end

    test "a fetch that outlasts its timeout is killed and fails", %{cache: cache} do
      Cache.get(cache, :k, blocked_fetcher({:ok, 1}), timeout: 10)
      assert_receive {:fetching, fetch_pid}
      ref = Process.monitor(fetch_pid)

      :ok = Cache.await(cache, :k)

      assert_receive {:DOWN, ^ref, :process, ^fetch_pid, :killed}
      assert Cache.get(cache, :k, fetcher({:ok, 2})) == {:unavailable, :timeout}
    end

    test "returns :unavailable when the cache is not running" do
      assert Cache.get(:no_such_cache, :k, fetcher({:ok, 1})) ==
               {:unavailable, :cache_not_running}

      refute_receive {:fetching, _}, 20
    end

    test "returns :unavailable while the cache is starting (table without its clock)" do
      name = :"cache_starting_#{System.unique_integer([:positive])}"
      :ets.new(name, [:named_table, :public])

      assert Cache.get(name, :k, fetcher({:ok, 1})) == {:unavailable, :cache_not_running}
    end

    test "a TTL that is not a number of at least 0 fails the fetch and keeps the cache", %{
      cache: cache,
      clock: clock
    } do
      fill(cache, :keep, {:ok, :kept}, ttl: 1_000_000)
      pid = Process.whereis(cache)

      for ttl <- [fn _ -> nil end, fn _ -> -1 end, fn _ -> "soon" end, -5, nil, :forever] do
        key = {:bad, inspect(ttl)}
        assert Cache.get(cache, key, fetcher({:ok, 1}), ttl: ttl) == :pending
        assert_receive {:fetching, _}
        :ok = Cache.await(cache, key)

        assert {:unavailable, {:bad_ttl, _ttl}} = Cache.get(cache, key, fetcher({:ok, 1}))
        assert Process.whereis(cache) == pid
        assert {:fresh, :kept, _as_of} = Cache.get(cache, :keep, fetcher({:ok, 2}))
      end

      # A TTL function that raises is a failed fetch too.
      Cache.get(cache, :raising, fetcher({:ok, 1}), ttl: fn _ -> raise "bad ttl" end)
      assert_receive {:fetching, _}
      :ok = Cache.await(cache, :raising)
      assert {:unavailable, {:exit, _reason}} = Cache.get(cache, :raising, fetcher({:ok, 1}))
      assert Process.whereis(cache) == pid

      # On a refresh, the old value stays and the backoff applies.
      fill(cache, :old, {:ok, :old}, ttl: 10)
      advance(clock, 100)
      Cache.get(cache, :old, fetcher({:ok, :new}), ttl: fn _ -> nil end, backoff: 500)
      assert_receive {:fetching, _}
      :ok = Cache.await(cache, :old)

      assert {:stale, :old, _as_of} = Cache.get(cache, :old, fetcher({:ok, :newer}))
      _ = :sys.get_state(cache)
      refute_receive {:fetching, _}, 20
    end
  end

  describe "await/3" do
    test "returns at once when nothing is running", %{cache: cache} do
      assert Cache.await(cache, :nothing) == :ok
    end
  end

  describe "max_entries" do
    defp start_small_cache(clock, max_entries) do
      name = :"cache_small_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Cache, name: name, max_entries: max_entries, clock: fn -> Agent.get(clock, & &1) end}
      )

      name
    end

    test "drops the least recently written keys", %{clock: clock} do
      name = start_small_cache(clock, 3)

      for key <- 1..4 do
        advance(clock, 1)
        fill(name, key, {:ok, key})
      end

      assert :ets.info(name, :size) - 1 == 3

      # Key 1 was written first: it is gone, the others stay.
      assert {:fresh, 4, _as_of} = Cache.get(name, 4, fetcher({:ok, :x}))
      assert {:fresh, 2, _as_of} = Cache.get(name, 2, fetcher({:ok, :x}))
      refute_receive {:fetching, _}, 20
      assert Cache.get(name, 1, fetcher({:ok, :x})) == :pending
      assert_receive {:fetching, _}
    end

    test "with a clock that never moves, the key just written stays", %{clock: clock} do
      name = start_small_cache(clock, 2)

      for key <- 1..6, do: fill(name, key, {:ok, key})

      assert :ets.info(name, :size) - 1 <= 2
      assert {:fresh, 6, _as_of} = Cache.get(name, 6, fetcher({:ok, :x}))
      assert {:fresh, 5, _as_of} = Cache.get(name, 5, fetcher({:ok, :x}))
      refute_receive {:fetching, _}, 20
    end

    test "a key that is being refreshed is not evicted", %{clock: clock} do
      name = start_small_cache(clock, 2)

      fill(name, :a, {:ok, :old}, ttl: 10)
      fill(name, :b, {:ok, :b})
      advance(clock, 100)

      # `:a` is the oldest entry and is being refreshed.
      assert {:stale, :old, _as_of} = Cache.get(name, :a, blocked_fetcher({:ok, :new}))
      assert_receive {:fetching, fetch_pid}

      # A third key goes over the limit: `:b` goes, not `:a`.
      fill(name, :c, {:ok, :c})
      assert {:stale, :old, _as_of} = Cache.get(name, :a, fetcher({:ok, :other}))
      assert Cache.get(name, :b, fetcher({:ok, :other})) == :pending

      send(fetch_pid, :release)
      :ok = Cache.await(name, :a)
      assert {:fresh, :new, _as_of} = Cache.get(name, :a, fetcher({:ok, :other}))
    end
  end
end
