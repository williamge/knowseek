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

  describe "evicting entries that were read" do
    defp read_counters(cache) do
      [{:meta, %{reads: reads}}] = :ets.lookup(cache, :meta)
      :ets.tab2list(reads)
    end

    test "a flood of distinct junk keys does not evict a key that was read after it was written",
         %{clock: clock} do
      name = start_small_cache(clock, 10)

      fill(name, :real, {:ok, :value})
      assert {:fresh, :value, _as_of} = Cache.get(name, :real, fetcher({:ok, :x}))

      # Junk is written once and never read again, as a flood of made-up queries is.
      for n <- 1..300 do
        advance(clock, 1)
        fill(name, {:junk, n}, {:ok, :none})
      end

      assert %{entries: entries} = Cache.stats(name)
      assert entries <= 10
      assert {:fresh, :value, _as_of} = Cache.get(name, :real, fetcher({:ok, :x}))
      refute_receive {:fetching, _}, 20
    end

    test "fewer reads go first, then the oldest", %{clock: clock} do
      name = start_small_cache(clock, 3)

      fill(name, :a, {:ok, :a})
      fill(name, :b, {:ok, :b})
      fill(name, :c, {:ok, :c})
      for _ <- 1..3, do: Cache.get(name, :a, fetcher({:ok, :x}))
      Cache.get(name, :b, fetcher({:ok, :x}))

      # `:c` was never read: it goes first, then each newer key that is never read.
      fill(name, :d, {:ok, :d})
      assert Cache.get(name, :c, fetcher({:ok, :x})) == :pending
      assert_receive {:fetching, _}
      :ok = Cache.await(name, :c)

      # Fetching `:c` again pushed out `:d` (never read, older than `:c`); a
      # fifth key pushes out `:c` in the same way. `:a` and `:b` stay.
      fill(name, :e, {:ok, :e})
      assert {:fresh, :a, _} = Cache.get(name, :a, fetcher({:ok, :x}))
      assert {:fresh, :b, _} = Cache.get(name, :b, fetcher({:ok, :x}))
      refute_receive {:fetching, _}, 20
    end

    test "the counters of evicted keys are deleted", %{clock: clock} do
      name = start_small_cache(clock, 10)

      for n <- 1..200 do
        advance(clock, 1)
        fill(name, n, {:ok, n})
        Cache.get(name, n, fetcher({:ok, :x}))
      end

      assert length(read_counters(name)) <= 10
    end

    test "a read does not call the cache process", %{cache: cache} do
      fill(cache, :k, {:ok, :v})

      :sys.suspend(cache)
      assert {:fresh, :v, _as_of} = Cache.get(cache, :k, fetcher({:ok, :x}))
      assert {:fresh, :v, _as_of} = Cache.get(cache, :k, fetcher({:ok, :x}))
      assert read_counters(cache) == [{:k, 2}]
      :sys.resume(cache)
    end

    test "misses and failures are not reads", %{cache: cache} do
      assert Cache.get(cache, :cold, blocked_fetcher({:ok, 1})) == :pending
      assert_receive {:fetching, _}
      fill(cache, :failed, {:error, :boom})
      assert {:unavailable, :boom} = Cache.get(cache, :failed, fetcher({:ok, 1}))

      assert read_counters(cache) == []
    end
  end

  describe "max_in_flight" do
    defp start_capped_cache(clock, max_in_flight) do
      name = :"cache_capped_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Cache, name: name, max_in_flight: max_in_flight, clock: fn -> Agent.get(clock, & &1) end}
      )

      name
    end

    test "at most that many fetches run at once; the others are dropped", %{clock: clock} do
      name = start_capped_cache(clock, 2)

      # Fifty distinct keys, as a client that makes up queries would send.
      for key <- 1..50, do: assert(Cache.get(name, key, blocked_fetcher({:ok, key})) == :pending)

      # Every refresh request has reached the cache process once this returns.
      _ = :sys.get_state(name)

      assert_receive {:fetching, first}
      assert_receive {:fetching, second}
      refute_receive {:fetching, _}, 50

      # Nothing was stored for the dropped keys, so the table stays small.
      assert :ets.info(name, :size) <= 1

      # A slot frees up: the next request for a dropped key is fetched.
      send(first, :release)
      send(second, :release)
      :ok = Cache.await(name, 1)
      :ok = Cache.await(name, 2)

      assert Cache.get(name, 3, fetcher({:ok, 3})) == :pending
      assert_receive {:fetching, _third}
      :ok = Cache.await(name, 3)
      assert {:fresh, 3, _as_of} = Cache.get(name, 3, fetcher({:ok, :x}))
    end

    test "drops are counted in stats/1 and logged as a warning, at most every 10 s", %{
      clock: clock
    } do
      name = start_capped_cache(clock, 1)
      Cache.get(name, :busy, blocked_fetcher({:ok, :v}))
      assert_receive {:fetching, _}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for key <- 1..30, do: Cache.get(name, key, blocked_fetcher({:ok, key}))
          assert %{dropped: 30, in_flight: 1} = Cache.stats(name)

          # Ten seconds later the next drop is logged again.
          advance(clock, 10_000)
          Cache.get(name, :another, blocked_fetcher({:ok, 1}))
          assert %{dropped: 31} = Cache.stats(name)
        end)

      warnings = log |> String.split("\n") |> Enum.filter(&String.contains?(&1, inspect(name)))
      assert length(warnings) == 2
      assert log =~ ": 1 refreshes dropped so far"
      assert log =~ ": 31 refreshes dropped so far"
      assert log =~ "1 fetches in flight of 1 (0 reserved for refreshes)"
    end

    test "stats/1 of a fresh cache", %{cache: cache} do
      assert Cache.stats(cache) == %{entries: 0, in_flight: 0, dropped: 0, blocked_until: 0}
    end

    test "the default is no cap", %{cache: cache} do
      for key <- 1..20, do: Cache.get(cache, key, blocked_fetcher({:ok, key}))
      _ = :sys.get_state(cache)

      for _ <- 1..20, do: assert_receive({:fetching, _pid})
    end
  end

  describe "reserve_for_refresh" do
    # Four slots, one of them reserved: new keys get three.
    setup %{clock: clock} do
      name = :"cache_reserved_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Cache,
         name: name,
         max_in_flight: 4,
         reserve_for_refresh: 1,
         clock: fn -> Agent.get(clock, & &1) end}
      )

      {:ok, reserved: name}
    end

    # A fetch that names its key and waits for the test to release it.
    defp keyed_fetcher(key, result) do
      test = self()

      fn ->
        send(test, {:fetching, key, self()})

        receive do
          :release -> result
        end
      end
    end

    # Hammers the cache with `count` distinct keys, as a client that makes up
    # queries would, and returns the fetch processes that started.
    defp flood(cache, count) do
      for n <- 1..count,
          do:
            assert(Cache.get(cache, {:junk, n}, keyed_fetcher({:junk, n}, {:ok, n})) == :pending)

      # Every refresh request has reached the cache process once this returns.
      _ = :sys.get_state(cache)
      collect_fetches()
    end

    defp collect_fetches(acc \\ []) do
      receive do
        {:fetching, key, pid} -> collect_fetches([{key, pid} | acc])
      after
        20 -> Enum.reverse(acc)
      end
    end

    test "junk keys fill only the new-key share: a refresh still starts, and a new key starts when a junk fetch ends",
         %{reserved: cache, clock: clock} do
      # A key with a value that has expired: it needs a refresh.
      Cache.get(cache, :real, fetcher({:ok, 1}), ttl: 1_000)
      :ok = Cache.await(cache, :real)
      assert_receive {:fetching, _}
      advance(clock, 5_000)

      junk = flood(cache, 200)
      assert length(junk) == 3
      assert %{in_flight: 3, dropped: 197} = Cache.stats(cache)

      # The refresh of the key with a value takes the reserved slot.
      assert {:stale, 1, _as_of} = Cache.get(cache, :real, keyed_fetcher(:real, {:ok, 2}))
      assert_receive {:fetching, :real, refresh_pid}
      assert %{in_flight: 4} = Cache.stats(cache)

      # A real new key is dropped while junk holds the new-key share ...
      assert Cache.get(cache, :new, keyed_fetcher(:new, {:ok, :n})) == :pending
      _ = :sys.get_state(cache)
      refute_receive {:fetching, :new, _}, 20

      # ... and so is another new key while the refresh runs ...
      send(refresh_pid, :release)
      :ok = Cache.await(cache, :real)
      assert {:fresh, 2, _as_of} = Cache.get(cache, :real, fetcher({:ok, :x}))
      assert Cache.get(cache, :new, keyed_fetcher(:new, {:ok, :n})) == :pending
      _ = :sys.get_state(cache)
      refute_receive {:fetching, :new, _}, 20

      # ... until a junk fetch ends: the next ask for the real key gets the slot.
      [{junk_key, junk_pid} | _] = junk
      send(junk_pid, :release)
      :ok = Cache.await(cache, junk_key)
      assert Cache.get(cache, :new, keyed_fetcher(:new, {:ok, :n})) == :pending
      assert_receive {:fetching, :new, new_pid}

      send(new_pid, :release)
      :ok = Cache.await(cache, :new)
      assert {:fresh, :n, _as_of} = Cache.get(cache, :new, fetcher({:ok, :x}))
    end

    test "refreshes of several keys can use all four slots when no new key runs",
         %{reserved: cache, clock: clock} do
      for key <- 1..4, do: fill(cache, key, {:ok, key}, ttl: 1_000)
      advance(clock, 5_000)

      for key <- 1..4,
          do: assert({:stale, ^key, _} = Cache.get(cache, key, keyed_fetcher(key, {:ok, 0})))

      _ = :sys.get_state(cache)

      assert length(collect_fetches()) == 4
      assert %{in_flight: 4, dropped: 0} = Cache.stats(cache)
    end

    test "a key whose fetches only failed is a new key, not a refresh", %{
      reserved: cache,
      clock: clock
    } do
      fill(cache, :failed, {:error, :boom}, backoff: 0)
      advance(clock, 1)
      assert {:unavailable, :boom} = Cache.get(cache, :failed, keyed_fetcher(:failed, {:ok, 1}))
      assert_receive {:fetching, :failed, failed_pid}
      send(failed_pid, :release)
      :ok = Cache.await(cache, :failed)
      assert {:fresh, 1, _as_of} = Cache.get(cache, :failed, fetcher({:ok, 2}))

      # With the new-key share full, a key that never had a value is dropped.
      fill(cache, :failed_again, {:error, :boom}, backoff: 0)
      _junk = flood(cache, 10)
      advance(clock, 1)

      assert {:unavailable, :boom} =
               Cache.get(cache, :failed_again, keyed_fetcher(:failed_again, {:ok, 1}))

      _ = :sys.get_state(cache)
      refute_receive {:fetching, :failed_again, _}, 20
    end

    test "an empty value (:empty_values) does not earn the reserve", %{clock: clock} do
      name = :"cache_empty_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Cache,
         name: name,
         max_in_flight: 4,
         reserve_for_refresh: 1,
         empty_values: [:none],
         clock: fn -> Agent.get(clock, & &1) end}
      )

      fill(name, :nothing, {:ok, :none}, ttl: 1_000)
      fill(name, :real, {:ok, 1}, ttl: 1_000)
      advance(clock, 5_000)

      _junk = flood(name, 10)
      assert %{in_flight: 3} = Cache.stats(name)

      # Expired, but it holds "nothing": a new key, dropped while the share is full.
      assert {:stale, :none, _} = Cache.get(name, :nothing, keyed_fetcher(:nothing, {:ok, :none}))
      _ = :sys.get_state(name)
      refute_receive {:fetching, :nothing, _}, 20

      assert {:stale, 1, _} = Cache.get(name, :real, keyed_fetcher(:real, {:ok, 2}))
      assert_receive {:fetching, :real, _}
    end

    test "the reserve must leave a slot for new keys" do
      for opts <- [
            [max_in_flight: 2, reserve_for_refresh: 2],
            [max_in_flight: :infinity, reserve_for_refresh: 1],
            [max_in_flight: 4, reserve_for_refresh: -1]
          ] do
        assert {:error, _reason} =
                 start_supervised(
                   {Cache, [name: :"cache_bad_#{System.unique_integer([:positive])}"] ++ opts}
                 )
      end
    end
  end

  describe "rate limits" do
    test "a rate-limited fetch stops every fetch of the cache until Retry-After", %{
      cache: cache,
      clock: clock
    } do
      assert Cache.get(cache, :a, fetcher({:error, {:rate_limited, 30_000}})) == :pending
      assert_receive {:fetching, _}
      :ok = Cache.await(cache, :a)

      # The failing key and every other key report the limit and start nothing.
      assert {:unavailable, {:rate_limited, 30_000}} =
               Cache.get(cache, :a, fetcher({:ok, :a}))

      advance(clock, 10_000)

      assert {:unavailable, {:rate_limited, 20_000}} =
               Cache.get(cache, :b, fetcher({:ok, :b}))

      _ = :sys.get_state(cache)
      refute_receive {:fetching, _}, 20

      # The block ends: fetching resumes.
      advance(clock, 20_001)
      assert Cache.get(cache, :b, fetcher({:ok, :b})) == :pending
      assert_receive {:fetching, _}
      :ok = Cache.await(cache, :b)
      assert {:fresh, :b, _as_of} = Cache.get(cache, :b, fetcher({:ok, :x}))
    end

    test "keys with a value keep it as stale and do not refresh during the block", %{
      cache: cache,
      clock: clock
    } do
      fill(cache, :kept, {:ok, :old}, ttl: 1_000)
      advance(clock, 5_000)

      # Another key hits the limit.
      Cache.get(cache, :other, fetcher({:error, {:rate_limited, 60_000}}))
      assert_receive {:fetching, _}
      :ok = Cache.await(cache, :other)

      assert {:stale, :old, _as_of} = Cache.get(cache, :kept, fetcher({:ok, :new}))
      _ = :sys.get_state(cache)
      refute_receive {:fetching, _}, 20

      advance(clock, 60_001)
      assert {:stale, :old, _as_of} = Cache.get(cache, :kept, fetcher({:ok, :new}))
      assert_receive {:fetching, _}
      :ok = Cache.await(cache, :kept)
      assert {:fresh, :new, _as_of} = Cache.get(cache, :kept, fetcher({:ok, :x}))
    end

    test "the block is at most ten minutes", %{cache: cache, clock: clock} do
      Cache.get(cache, :a, fetcher({:error, {:rate_limited, :timer.hours(5)}}))
      assert_receive {:fetching, _}
      :ok = Cache.await(cache, :a)

      advance(clock, :timer.minutes(10) + 1)
      Cache.get(cache, :b, fetcher({:ok, :b}))
      assert_receive {:fetching, _}
    end

    test "rate_limited/1 reads Retry-After in seconds, else waits a minute" do
      response = fn headers -> %Req.Response{status: 429, headers: headers} end

      assert Cache.rate_limited(response.(%{"retry-after" => ["7"]})) == {:rate_limited, 7_000}
      assert Cache.rate_limited(response.(%{})) == {:rate_limited, 60_000}

      assert Cache.rate_limited(response.(%{"retry-after" => ["Wed, 21 Oct 2026 07:28:00 GMT"]})) ==
               {:rate_limited, 60_000}
    end
  end
end
