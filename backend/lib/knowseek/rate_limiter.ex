defmodule Knowseek.RateLimiter do
  @moduledoc """
  An in-memory token-bucket rate limiter (ADR 0023). `KnowseekWeb.Plugs.RateLimit`
  uses it to limit anonymous clients per endpoint; nothing else depends on it.

  `hit/4` takes one token from the bucket of `key`:

      case Knowseek.RateLimiter.hit({:search, client}, 30, 60_000) do
        :ok -> ...
        {:error, retry_after_ms} -> ...
      end

  A bucket holds at most `limit` tokens (the burst) and refills `limit` tokens
  per `window_ms` (`limit / window_ms` per millisecond), so a client that
  keeps going settles at `limit` requests per window. A new key starts full.
  A denied hit takes nothing. The error says in how many milliseconds a token
  is available.

  Time is integer arithmetic (a token is `window_ms` units, a millisecond
  refills `limit` units), so the answers are exact and a fake clock gives
  deterministic tests.

  ## One process, bounded memory

  One process owns every bucket and answers each hit with a call, so the
  check and the take cannot race. That is a few microseconds a request, far
  below what the endpoints cost. The memory is bounded, because the keys come
  from the network:

    * A bucket that has refilled completely is the same as no bucket. A
      periodic sweep (`:sweep_interval`) drops these, losing nothing.
    * At most `:max_buckets` buckets are kept. A new key that would pass the
      cap first sweeps the full buckets; if the table is still full, the least
      recently used 10% (at least one) are dropped. A dropped client starts
      over with a full bucket, which is the price of the cap: an attacker who
      sends from more addresses than the cap can reset other clients' buckets,
      but cannot grow memory. Dropping 10% at once keeps the cost per hit low.

  The state is lost on restart (the limits then start over), and nothing is
  written to the database. If the limiter process cannot be reached, `hit/4`
  allows the request and logs an error: a limiter outage must not take the API
  down.

  ## Options of `start_link/1`

    * `:name` - required, an atom.
    * `:clock` - a function returning milliseconds. Default
      `System.monotonic_time(:millisecond)`.
    * `:max_buckets` - default `50_000`.
    * `:sweep_interval` - milliseconds between sweeps. Default one minute.
      `:infinity` turns the timer off (tests call `sweep/1`).
  """
  use GenServer

  require Logger

  @default_max_buckets 50_000
  @default_sweep_interval :timer.minutes(1)

  @type key :: term()
  @type server :: GenServer.server()

  ## Client

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  def child_spec(opts) do
    %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  @doc """
  Takes a token of `key`'s bucket, which holds `limit` tokens and refills them
  in `window_ms`. Returns `:ok`, or `{:error, retry_after_ms}` (at least 1).
  """
  @spec hit(server(), key(), pos_integer(), pos_integer()) ::
          :ok | {:error, retry_after_ms :: pos_integer()}
  def hit(server \\ __MODULE__, key, limit, window_ms)
      when is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 do
    GenServer.call(server, {:hit, key, limit, window_ms})
  catch
    :exit, reason ->
      Logger.error("rate limiter unreachable, request allowed: #{inspect(reason)}")
      :ok
  end

  @doc "Drops the buckets that have refilled completely. Returns how many."
  @spec sweep(server()) :: non_neg_integer()
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep)

  @doc "The number of buckets kept."
  @spec size(server()) :: non_neg_integer()
  def size(server \\ __MODULE__), do: GenServer.call(server, :size)

  ## Server

  @impl true
  def init(opts) do
    state = %{
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      max_buckets: Keyword.get(opts, :max_buckets, @default_max_buckets),
      sweep_interval: Keyword.get(opts, :sweep_interval, @default_sweep_interval),
      buckets: %{}
    }

    schedule_sweep(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:hit, key, limit, window_ms}, _from, state) do
    now = state.clock.()
    capacity = limit * window_ms

    {units, state} =
      case Map.fetch(state.buckets, key) do
        {:ok, bucket} -> {refill(bucket, now, capacity, limit), state}
        :error -> {capacity, make_room(state, now)}
      end

    if units >= window_ms do
      bucket = %{units: units - window_ms, at: now, limit: limit, window_ms: window_ms}
      {:reply, :ok, %{state | buckets: Map.put(state.buckets, key, bucket)}}
    else
      bucket = %{units: units, at: now, limit: limit, window_ms: window_ms}
      retry_after = div(window_ms - units + limit - 1, limit)

      {:reply, {:error, max(retry_after, 1)},
       %{state | buckets: Map.put(state.buckets, key, bucket)}}
    end
  end

  def handle_call(:sweep, _from, state) do
    {state, dropped} = drop_full(state, state.clock.())
    {:reply, dropped, state}
  end

  def handle_call(:size, _from, state), do: {:reply, map_size(state.buckets), state}

  @impl true
  def handle_info(:sweep, state) do
    {state, _dropped} = drop_full(state, state.clock.())
    schedule_sweep(state)
    {:noreply, state}
  end

  defp schedule_sweep(%{sweep_interval: :infinity}), do: :ok
  defp schedule_sweep(%{sweep_interval: ms}), do: Process.send_after(self(), :sweep, ms)

  # Tokens (in units) of `bucket` at `now`, capped at its capacity.
  defp refill(%{units: units, at: at}, now, capacity, limit),
    do: min(capacity, units + max(now - at, 0) * limit)

  defp full?(bucket, now) do
    refill(bucket, now, bucket.limit * bucket.window_ms, bucket.limit) >=
      bucket.limit * bucket.window_ms
  end

  defp drop_full(state, now) do
    buckets = Map.reject(state.buckets, fn {_key, bucket} -> full?(bucket, now) end)
    {%{state | buckets: buckets}, map_size(state.buckets) - map_size(buckets)}
  end

  # Room for one more bucket: the full ones go first, then the least recently
  # used 10%.
  defp make_room(%{buckets: buckets, max_buckets: max} = state, now)
       when map_size(buckets) >= max do
    {state, _dropped} = drop_full(state, now)

    if map_size(state.buckets) >= max do
      oldest =
        state.buckets
        |> Enum.sort_by(fn {_key, bucket} -> bucket.at end)
        |> Enum.take(max(div(max, 10), 1))
        |> Enum.map(&elem(&1, 0))

      %{state | buckets: Map.drop(state.buckets, oldest)}
    else
      state
    end
  end

  defp make_room(state, _now), do: state
end
