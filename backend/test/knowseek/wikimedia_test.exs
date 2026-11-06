defmodule Knowseek.WikimediaTest do
  # Every test starts its own limiter, so the global one is not involved.
  use ExUnit.Case, async: true

  alias Knowseek.Wikimedia

  setup do
    server = :"wikimedia_#{System.unique_integer([:positive])}"
    start_supervised!({Wikimedia, name: server, max_concurrent: 3, background_max: 2})
    {:ok, server: server}
  end

  # A caller that holds its slot until it gets `:release`. It reports
  # `{:running, label, pid}` once it has a slot and `{:done, label}` after.
  defp start_caller(server, class, label) do
    test = self()

    spawn(fn ->
      Wikimedia.run(server, class, fn ->
        send(test, {:running, label, self()})

        receive do
          :release -> :ok
        end
      end)

      send(test, {:done, label})
    end)
  end

  # A caller that must wait: returns once the limiter has its request, so the
  # order of waiters is the order of these calls.
  defp start_waiter(server, class, label) do
    pid = GenServer.whereis(server)
    :erlang.trace(pid, true, [:receive])
    caller = start_caller(server, class, label)
    assert_receive {:trace, ^pid, :receive, {:"$gen_call", {^caller, _tag}, {:acquire, ^class}}}
    :erlang.trace(pid, false, [:receive])
    caller
  end

  # A caller that gets a slot at once. Returns its pid.
  defp hold(server, class, label) do
    start_caller(server, class, label)
    running(label)
  end

  defp running(label) do
    assert_receive {:running, ^label, pid}
    pid
  end

  defp next_running do
    assert_receive {:running, _label, pid}
    pid
  end

  test "runs the function in the caller's process and returns its result", %{server: server} do
    assert Wikimedia.run(server, :interactive, fn -> self() end) == self()
    assert Wikimedia.run(server, :background, fn -> :done end) == :done
  end

  test "no more than max_concurrent run at once", %{server: server} do
    for n <- 1..10, do: start_caller(server, :interactive, n)

    pids = for _slot <- 1..3, do: next_running()
    refute_receive {:running, _label, _pid}, 50
    assert %{interactive: 3, waiting_interactive: 7} = Wikimedia.stats(server)

    # Each released slot lets exactly one more in.
    send(hd(pids), :release)
    next_running()
    refute_receive {:running, _label, _pid}, 50
  end

  test "background callers hold at most background_max slots", %{server: server} do
    for n <- 1..5, do: start_caller(server, :background, n)

    bg = for _slot <- 1..2, do: next_running()
    refute_receive {:running, _label, _pid}, 50

    # The third slot is still free for an interactive caller.
    hold(server, :interactive, :lookup)

    assert Wikimedia.stats(server) == %{
             interactive: 1,
             background: 2,
             waiting_interactive: 0,
             waiting_background: 3
           }

    send(hd(bg), :release)
    next_running()
    refute_receive {:running, _label, _pid}, 50
  end

  test "a freed slot goes to an interactive waiter before an older background one", %{
    server: server
  } do
    first = for n <- 1..3, do: hold(server, :interactive, n)

    start_waiter(server, :background, :discovery)
    start_waiter(server, :interactive, :lookup)

    send(hd(first), :release)
    running(:lookup)
    refute_received {:running, :discovery, _pid}

    send(Enum.at(first, 1), :release)
    running(:discovery)
  end

  test "interactive waiters are served in order", %{server: server} do
    first = for n <- 1..3, do: hold(server, :interactive, n)

    start_waiter(server, :interactive, :a)
    start_waiter(server, :interactive, :b)

    send(hd(first), :release)
    running(:a)
    refute_receive {:running, :b, _pid}, 50
  end

  test "a holder that dies gives its slot back", %{server: server} do
    holders = for n <- 1..3, do: hold(server, :interactive, n)
    start_waiter(server, :interactive, :next)

    Process.exit(hd(holders), :kill)
    running(:next)
  end

  test "a waiter that dies leaves the queue", %{server: server} do
    holders = for n <- 1..3, do: hold(server, :interactive, n)
    gone = start_waiter(server, :interactive, :gone)
    start_waiter(server, :interactive, :next)

    ref = Process.monitor(gone)
    Process.exit(gone, :kill)
    assert_receive {:DOWN, ^ref, :process, ^gone, :killed}
    assert %{waiting_interactive: 1} = Wikimedia.stats(server)

    send(hd(holders), :release)
    running(:next)
  end

  test "a function that raises gives its slot back", %{server: server} do
    assert_raise RuntimeError, fn ->
      Wikimedia.run(server, :background, fn -> raise "boom" end)
    end

    assert %{interactive: 0, background: 0} = Wikimedia.stats(server)
  end

  test "rejects a background_max out of range" do
    Process.flag(:trap_exit, true)

    for {max, background_max} <- [{3, 0}, {3, 4}, {0, 0}] do
      assert {:error, {%ArgumentError{}, _stack}} =
               Wikimedia.start_link(
                 name: :"wikimedia_bad_#{max}_#{background_max}",
                 max_concurrent: max,
                 background_max: background_max
               )
    end
  end
end
