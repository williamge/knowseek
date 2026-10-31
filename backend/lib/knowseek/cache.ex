defmodule Knowseek.Cache do
  @moduledoc """
  A disposable in-memory cache with a background refresher (ADR 0017,
  decision 4). Entity resolution (`Knowseek.Entities`) and the live fact cards
  (`Knowseek.Cards`) use it, each with its own instance.

  `get/4` reads an ETS table and never calls the fetch function in the
  caller's process. When the entry is missing or past its TTL, `get/4` asks
  the cache process to refresh it and returns at once. The refresh runs in a
  supervised task. Per key:

    * **Single-flight.** Many callers cost one fetch. While a fetch runs, or
      right after one stored a fresh value, further requests do nothing.
    * **Stale-while-revalidate.** An expired value is still returned (as
      `:stale`) while the refresh runs.
    * **Failure keeps the old value.** A failed, crashed, or timed-out fetch
      leaves the stored value in place and sets a backoff: for `:backoff`
      milliseconds no new fetch starts, so a down upstream is not hammered.
      With no value ever stored, `get/4` returns `{:unavailable, reason}`.
    * **TTL.** A fetched value is `:fresh` for `:ttl` milliseconds.
    * **Cap on concurrent fetches.** At most `:max_in_flight` fetches run at
      once. A refresh that would be the next one is dropped, not queued: the
      key stays `:pending` and the next `get/4` asks again. N distinct
      (user-chosen) keys cost at most `:max_in_flight` upstream calls at a time.
      Every drop is counted (`stats/1`) and logged as a warning, at most once
      every ten seconds, so that a flood of distinct keys shows up. A flood
      can keep every slot busy and leave a real key `:pending`: the cap bounds
      the upstream load, it does not decide who gets the slots.
    * **Cache-wide rate-limit backoff.** A fetch that fails with
      `{:error, {:rate_limited, retry_after_ms}}` (the upstream said 429, or
      `maxlag`, with a `Retry-After`) stops *every* fetch of this cache until
      the time is up (at most ten minutes). Keys with a value keep returning it
      as `:stale`; keys without one return
      `{:unavailable, {:rate_limited, ms_left}}`. Give each upstream its own
      cache instance, so that one upstream's limit does not stop another's.

  The cache is lost on restart. Nothing writes to the database, and nothing
  runs for a key that nobody asks for.

  ## Usage

      # in the supervision tree
      {Knowseek.Cache, name: MyApp.Cache}

      case Knowseek.Cache.get(MyApp.Cache, key, fn -> fetch(key) end, ttl: 60_000) do
        {:fresh, value, as_of} -> ...
        {:stale, value, as_of} -> ...
        :pending -> ...
        {:unavailable, reason} -> ...
      end

  The fetch function takes no arguments and returns `{:ok, value}` or
  `{:error, reason}`. A value can be any term, including `nil` or `:none`:
  an "empty" answer is cached like any other.

  ## Options of `get/4`

  The options of the call that starts a refresh apply to that refresh.

    * `:ttl` - how long a fetched value is fresh, in milliseconds. A
      function of one argument is called with the fetched value and returns
      the milliseconds (a live game and a final game get different TTLs).
      Default `60_000`.
    * `:backoff` - milliseconds without a new fetch after a failure.
      Default `5_000`.
    * `:timeout` - milliseconds a fetch may run before it is killed and
      counted as a failure (`{:error, :timeout}`). Default `10_000`.

  ## Options of `start_link/1`

    * `:name` - required, an atom. Names both the process and its ETS table.
    * `:clock` - a function returning the current time in milliseconds. Tests
      inject one. Default `System.system_time(:millisecond)`.
    * `:max_entries` - at most this many keys are kept. Above it, the least
      recently written ones (10%, at least one) are dropped. Default `10_000`.
    * `:max_in_flight` - at most this many fetches run at once. Default
      `:infinity`. Caches whose keys come from user input set it.
  """
  use GenServer

  require Logger

  @default_ttl 60_000
  @default_backoff 5_000
  @default_timeout 10_000
  @default_max_entries 10_000
  @max_rate_limit_backoff :timer.minutes(10)
  @drop_log_interval :timer.seconds(10)

  @type key :: term()
  @type cache :: atom()
  @type fetch_fun :: (-> {:ok, term()} | {:error, term()})
  @type result ::
          {:fresh, value :: term(), as_of :: DateTime.t()}
          | {:stale, value :: term(), as_of :: DateTime.t()}
          | :pending
          | {:unavailable, reason :: term()}

  ## Client

  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :name),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns what the cache holds for `key` and, when the entry is missing or
  expired and no backoff applies, asks the cache process to refresh it with
  `fetch_fun`. Never waits for the fetch.

  Results:

    * `{:fresh, value, as_of}` - within its TTL. `as_of` is when it was fetched.
    * `{:stale, value, as_of}` - past its TTL. A refresh runs unless a backoff
      is active.
    * `:pending` - nothing stored and nothing failed yet. A fetch was started.
    * `{:unavailable, reason}` - nothing ever succeeded, and the last fetch
      failed with `reason`.

  If the cache is not running, returns `{:unavailable, :cache_not_running}`.
  """
  @spec get(cache(), key(), fetch_fun(), keyword()) :: result()
  def get(cache, key, fetch_fun, opts \\ []) when is_atom(cache) and is_function(fetch_fun, 0) do
    now = now(cache)
    entry = lookup(cache, key)
    blocked_until = blocked_until(cache)

    if blocked_until <= now and refresh_due?(entry, now),
      do: GenServer.cast(cache, {:refresh, key, fetch_fun, opts})

    classify(entry, now, blocked_until)
  rescue
    # The ETS table is gone while the cache process restarts.
    ArgumentError -> {:unavailable, :cache_not_running}
  end

  @doc """
  Blocks until the fetch running for `key` (if any) has finished and its
  result is stored. Returns `:ok` at once when nothing is running.

  The default timeout is `:infinity`: the wait is bounded by the fetch's own
  `:timeout` (see `get/4`), after which the cache stores a failure and
  replies. A finite `timeout` exits the caller if it runs out first.

  For tests and scripts that need the result of a `get/4` that returned
  `:pending`. The request path never calls it.
  """
  @spec await(cache(), key(), timeout()) :: :ok
  def await(cache, key, timeout \\ :infinity) when is_atom(cache) do
    GenServer.call(cache, {:await, key}, timeout)
  end

  @doc """
  Counters of the cache, for logs and tests: `entries` (keys stored),
  `in_flight` (fetches running), `dropped` (refreshes dropped over
  `:max_in_flight` since the start) and `blocked_until` (the end of a
  rate-limit stop, in the clock's milliseconds, or 0).
  """
  @spec stats(cache()) :: %{
          entries: non_neg_integer(),
          in_flight: non_neg_integer(),
          dropped: non_neg_integer(),
          blocked_until: non_neg_integer()
        }
  def stats(cache) when is_atom(cache), do: GenServer.call(cache, :stats)

  @default_retry_after 60_000

  @doc """
  The `{:rate_limited, retry_after_ms}` reason for a rate-limited upstream
  `Req.Response` (HTTP 429, or Wikidata's `maxlag`), for fetch functions to
  return as `{:error, reason}`. Reads `Retry-After` in seconds (an HTTP date
  or a missing header is one minute).
  """
  @spec rate_limited(Req.Response.t()) :: {:rate_limited, non_neg_integer()}
  def rate_limited(%Req.Response{} = response) do
    ms =
      with [value | _] <- Req.Response.get_header(response, "retry-after"),
           {seconds, ""} when seconds >= 0 <- Integer.parse(String.trim(value)) do
        seconds * 1000
      else
        _ -> @default_retry_after
      end

    {:rate_limited, ms}
  end

  ## Entry logic (pure)

  defp lookup(cache, key) do
    case :ets.lookup(cache, {:entry, key}) do
      [{_key, entry}] -> entry
      [] -> nil
    end
  end

  defp now(cache) do
    case :ets.lookup(cache, :meta) do
      [{:meta, %{clock: clock}}] -> clock.()
      # The table exists but `init/1` has not stored the clock yet.
      [] -> raise ArgumentError, "cache #{inspect(cache)} is starting"
    end
  end

  defp blocked_until(cache) do
    case :ets.lookup(cache, :blocked_until) do
      [{:blocked_until, ms}] -> ms
      [] -> 0
    end
  end

  defp classify(nil, now, blocked_until) when blocked_until > now,
    do: {:unavailable, {:rate_limited, blocked_until - now}}

  defp classify(nil, _now, _blocked_until), do: :pending

  defp classify(%{result: {:ok, value}, as_of: as_of, expires_at: expires_at}, now, _blocked) do
    status = if now < expires_at, do: :fresh, else: :stale
    {status, value, DateTime.from_unix!(as_of, :millisecond)}
  end

  defp classify(%{result: nil, error: error}, _now, _blocked), do: {:unavailable, error}

  defp refresh_due?(nil, _now), do: true

  defp refresh_due?(entry, now) do
    expired? = is_nil(entry.result) or now >= entry.expires_at
    backing_off? = entry.retry_at != nil and now < entry.retry_at
    expired? and not backing_off?
  end

  ## Server

  @impl true
  def init(opts) do
    cache = Keyword.fetch!(opts, :name)
    clock = Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end)

    # The task supervisor is linked: if it dies the cache dies with it, and
    # the parent supervisor restarts both.
    {:ok, task_sup} = Task.Supervisor.start_link()

    :ets.new(cache, [:named_table, :protected, read_concurrency: true])
    :ets.insert(cache, {:meta, %{clock: clock}})

    {:ok,
     %{
       cache: cache,
       clock: clock,
       task_sup: task_sup,
       max_entries: Keyword.get(opts, :max_entries, @default_max_entries),
       max_in_flight: Keyword.get(opts, :max_in_flight, :infinity),
       blocked_until: 0,
       dropped: 0,
       last_drop_log: nil,
       in_flight: %{},
       waiters: %{}
     }}
  end

  @impl true
  def handle_cast({:refresh, key, fetch_fun, opts}, state) do
    now = state.clock.()

    # Callers decide on a stale read, so re-check here: the entry may have
    # been refreshed since, and a fetch may be running already.
    cond do
      Map.has_key?(state.in_flight, key) -> {:noreply, state}
      state.blocked_until > now -> {:noreply, state}
      not refresh_due?(lookup(state.cache, key), now) -> {:noreply, state}
      at_capacity?(state) -> {:noreply, drop(state, now)}
      true -> {:noreply, start_fetch(state, key, fetch_fun, opts)}
    end
  end

  defp at_capacity?(%{max_in_flight: :infinity}), do: false
  defp at_capacity?(state), do: map_size(state.in_flight) >= state.max_in_flight

  defp drop(state, now) do
    state = %{state | dropped: state.dropped + 1}

    if state.last_drop_log == nil or now - state.last_drop_log >= @drop_log_interval do
      Logger.warning(
        "#{inspect(state.cache)}: #{state.dropped} refreshes dropped so far, " <>
          "#{state.max_in_flight} fetches already in flight"
      )

      %{state | last_drop_log: now}
    else
      state
    end
  end

  @impl true
  def handle_call({:await, key}, from, state) do
    if Map.has_key?(state.in_flight, key) do
      {:noreply, %{state | waiters: Map.update(state.waiters, key, [from], &[from | &1])}}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      entries: entry_count(state.cache),
      in_flight: map_size(state.in_flight),
      dropped: state.dropped,
      blocked_until: state.blocked_until
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case pop_in_flight(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {{key, flight}, state} ->
        Process.demonitor(ref, [:flush])
        {:noreply, finish(state, key, flight, result)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case pop_in_flight(state, ref) do
      {nil, state} -> {:noreply, state}
      {{key, flight}, state} -> {:noreply, finish(state, key, flight, {:error, {:exit, reason}})}
    end
  end

  def handle_info({:fetch_timeout, ref}, state) do
    case pop_in_flight(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {{key, flight}, state} ->
        # A result may have arrived just before the kill.
        result =
          case Task.shutdown(flight.task, :brutal_kill) do
            {:ok, result} -> result
            _no_reply -> {:error, :timeout}
          end

        {:noreply, finish(state, key, flight, result)}
    end
  end

  defp start_fetch(state, key, fetch_fun, opts) do
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    backoff = Keyword.get(opts, :backoff, @default_backoff)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    task = Task.Supervisor.async_nolink(state.task_sup, fn -> run_fetch(fetch_fun, ttl) end)
    timer = Process.send_after(self(), {:fetch_timeout, task.ref}, timeout)
    flight = %{task: task, timer: timer, backoff: backoff, key: key}

    %{state | in_flight: Map.put(state.in_flight, key, flight)}
  end

  # Runs in the task, so that a crashing fetch function or TTL function
  # cannot take the cache process down. A TTL that is not a number of at
  # least 0 fails the fetch.
  defp run_fetch(fetch_fun, ttl) do
    case fetch_fun.() do
      {:ok, value} -> with_ttl(value, ttl)
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_return, other}}
    end
  end

  defp with_ttl(value, ttl) do
    ms = if is_function(ttl, 1), do: ttl.(value), else: ttl

    if is_number(ms) and ms >= 0, do: {:ok, value, ms}, else: {:error, {:bad_ttl, ms}}
  end

  defp pop_in_flight(state, ref) do
    case Enum.find(state.in_flight, fn {_key, flight} -> flight.task.ref == ref end) do
      nil ->
        {nil, state}

      {key, flight} ->
        Process.cancel_timer(flight.timer)
        {{key, flight}, %{state | in_flight: Map.delete(state.in_flight, key)}}
    end
  end

  defp finish(state, key, flight, result) do
    now = state.clock.()
    previous = lookup(state.cache, key)

    entry =
      case result do
        {:ok, value, ttl} ->
          %{
            result: {:ok, value},
            as_of: now,
            expires_at: now + ttl,
            retry_at: nil,
            error: nil,
            seq: next_seq()
          }

        {:error, reason} ->
          failed(previous, reason, now, backoff_for(reason, flight.backoff))
      end

    :ets.insert(state.cache, {{:entry, key}, entry})
    evict(state)

    {waiters, remaining} = Map.pop(state.waiters, key, [])
    Enum.each(waiters, &GenServer.reply(&1, :ok))
    block(%{state | waiters: remaining}, result, now)
  end

  # A rate limit from the upstream stops every fetch, not just this key's.
  defp block(state, {:error, {:rate_limited, ms}}, now) when is_number(ms) and ms >= 0 do
    blocked_until = max(state.blocked_until, now + min(trunc(ms), @max_rate_limit_backoff))
    :ets.insert(state.cache, {:blocked_until, blocked_until})
    %{state | blocked_until: blocked_until}
  end

  defp block(state, _result, _now), do: state

  defp backoff_for({:rate_limited, ms}, backoff) when is_number(ms),
    do: max(backoff, min(trunc(ms), @max_rate_limit_backoff))

  defp backoff_for(_reason, backoff), do: backoff

  # The old value, if any, stays.
  defp failed(nil, reason, now, backoff) do
    %{
      result: nil,
      as_of: nil,
      expires_at: nil,
      retry_at: now + backoff,
      error: reason,
      seq: next_seq()
    }
  end

  defp failed(previous, reason, now, backoff) do
    %{previous | error: reason, retry_at: now + backoff, seq: next_seq()}
  end

  defp next_seq, do: System.unique_integer([:monotonic])

  # `:meta` and `:blocked_until` are rows too, so count only the entries.
  defp entry_count(cache),
    do: :ets.select_count(cache, [{{{:entry, :_}, :_}, [], [true]}])

  # Entries go in order of `seq`, a counter that never repeats, so equal clock
  # readings cannot make the key that was just written the oldest. Keys that
  # are being fetched stay.
  defp evict(%{cache: cache, max_entries: max_entries} = state) do
    if entry_count(cache) > max_entries do
      busy = Map.keys(state.in_flight)

      oldest =
        cache
        |> :ets.select([{{{:entry, :"$1"}, %{seq: :"$2"}}, [], [{{:"$2", :"$1"}}]}])
        |> Enum.reject(fn {_seq, key} -> key in busy end)
        |> Enum.sort()
        |> Enum.take(max(div(max_entries, 10), 1))

      Enum.each(oldest, fn {_seq, key} -> :ets.delete(cache, {:entry, key}) end)
    end

    :ok
  end
end
