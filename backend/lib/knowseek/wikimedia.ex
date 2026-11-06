defmodule Knowseek.Wikimedia do
  @moduledoc """
  Caps the Wikimedia requests that run at once, across all callers (ADR 0027).

  Wikimedia asks every client to "limit the number of concurrent requests to
  3 or fewer", across all its sites (Wikipedia, Wikidata, ...). Every request
  to a Wikimedia API runs inside `run/3`, which takes one of the slots for the
  length of `fun` and gives it back when `fun` returns, raises or exits.

  Callers have a class:

    * `:interactive` - a user is waiting (the entity lookups of
      `Knowseek.Entities.Wikidata`). It may use every slot, and a freed slot
      goes to the oldest interactive waiter first.
    * `:background` - nobody is waiting (the discovery jobs of
      `Knowseek.Discovery.Sources.Wikipedia`). It may hold at most
      `:background_max` slots, so the others stay free for interactive
      requests, and it gets a freed slot only when no interactive request
      waits.

  A caller that finds no free slot waits, in order within its class, with no
  time limit: every holder ends within its own HTTP timeouts. A caller that
  dies while it waits or holds a slot (for example a cache fetch task killed at
  its timeout) leaves the queue or gives the slot back.

  The limit is per node.

  Options:

    * `:name` - the registered name (required).
    * `:max_concurrent` - slots in all. Default 3.
    * `:background_max` - slots `:background` callers may hold at once, from 1
      to `:max_concurrent`. Default 2.
  """
  use GenServer

  @type class :: :interactive | :background
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
  Runs `fun` in the caller's process once a slot of `class` is free, and
  returns its result. Waits as long as it takes.
  """
  @spec run(server(), class(), (-> result)) :: result when result: term()
  def run(server \\ __MODULE__, class, fun)
      when class in [:interactive, :background] and is_function(fun, 0) do
    ref = GenServer.call(server, {:acquire, class}, :infinity)

    try do
      fun.()
    after
      GenServer.cast(server, {:release, ref})
    end
  end

  @doc """
  Slots held now (`interactive`, `background`) and callers waiting
  (`waiting_interactive`, `waiting_background`).
  """
  @spec stats(server()) :: %{
          interactive: non_neg_integer(),
          background: non_neg_integer(),
          waiting_interactive: non_neg_integer(),
          waiting_background: non_neg_integer()
        }
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  ## Server

  @impl true
  def init(opts) do
    max = Keyword.get(opts, :max_concurrent, 3)
    background_max = Keyword.get(opts, :background_max, 2)
    validate!(max, background_max)

    {:ok,
     %{
       max: max,
       background_max: background_max,
       # Monitor ref => class, one per held slot.
       holders: %{},
       background: 0,
       # Queues of {monitor ref, from}, oldest first.
       waiting: %{interactive: :queue.new(), background: :queue.new()}
     }}
  end

  defp validate!(max, background_max)
       when is_integer(max) and max > 0 and is_integer(background_max) and
              background_max in 1..max//1,
       do: :ok

  defp validate!(max, background_max) do
    raise ArgumentError,
          "invalid :max_concurrent #{inspect(max)} or :background_max #{inspect(background_max)}: " <>
            "max_concurrent must be a positive integer and background_max from 1 to max_concurrent"
  end

  @impl true
  def handle_call({:acquire, class}, {pid, _tag} = from, state) do
    ref = Process.monitor(pid)

    if free?(state, class) do
      {:reply, ref, hold(state, ref, class)}
    else
      {:noreply, update_in(state.waiting[class], &:queue.in({ref, from}, &1))}
    end
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      interactive: map_size(state.holders) - state.background,
      background: state.background,
      waiting_interactive: :queue.len(state.waiting.interactive),
      waiting_background: :queue.len(state.waiting.background)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:release, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> drop_holder(ref) |> grant_waiting()}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state =
      if Map.has_key?(state.holders, ref) do
        state |> drop_holder(ref) |> grant_waiting()
      else
        drop_waiter(state, ref)
      end

    {:noreply, state}
  end

  defp free?(state, :interactive), do: map_size(state.holders) < state.max

  defp free?(state, :background),
    do: map_size(state.holders) < state.max and state.background < state.background_max

  defp hold(state, ref, class) do
    state = put_in(state.holders[ref], class)
    if class == :background, do: %{state | background: state.background + 1}, else: state
  end

  defp drop_holder(state, ref) do
    case Map.pop(state.holders, ref) do
      {nil, _holders} -> state
      {:background, holders} -> %{state | holders: holders, background: state.background - 1}
      {:interactive, holders} -> %{state | holders: holders}
    end
  end

  defp drop_waiter(state, ref) do
    filter = fn queue -> :queue.filter(fn {waiter, _from} -> waiter != ref end, queue) end
    %{state | waiting: Map.new(state.waiting, fn {class, queue} -> {class, filter.(queue)} end)}
  end

  # Gives free slots to the waiters, interactive ones first.
  defp grant_waiting(state) do
    case next_waiter(state) do
      nil ->
        state

      {class, {ref, from}, queue} ->
        GenServer.reply(from, ref)
        state = put_in(state.waiting[class], queue)
        state |> hold(ref, class) |> grant_waiting()
    end
  end

  defp next_waiter(state) do
    Enum.find_value([:interactive, :background], fn class ->
      with true <- free?(state, class),
           {{:value, waiter}, queue} <- :queue.out(state.waiting[class]) do
        {class, waiter, queue}
      else
        _none -> nil
      end
    end)
  end
end
