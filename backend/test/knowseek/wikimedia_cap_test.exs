defmodule Knowseek.WikimediaCapTest do
  # Uses the global Knowseek.Wikimedia limiter and counts its exact load, and
  # the stubs run in other processes (jobs, cache tasks): not async.
  use Knowseek.DataCase, async: false

  import Req.Test, only: [set_req_test_from_context: 1]

  alias Knowseek.{Cache, Discovery, Entities, Wikimedia}
  alias Knowseek.Discovery.Sources.Wikipedia
  alias Knowseek.Entities.Wikidata

  @wikipedia_fixtures Path.expand("../support/fixtures/wikipedia", __DIR__)

  # Atomics: requests in flight, peak, Wikipedia requests in flight, Wikipedia
  # peak, requests in all, and 1 once requests no longer wait for the test.
  @in_flight 1
  @peak 2
  @wikipedia_in_flight 3
  @wikipedia_peak 4
  @total 5
  @released 6

  setup :set_req_test_from_context

  setup do
    cache = :"entities_cap_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, name: cache, max_in_flight: 4})
    {:ok, cache: cache}
  end

  test "5 discovery runs and 4 entity lookups make at most 3 Wikimedia requests at once", %{
    cache: cache
  } do
    counts = :atomics.new(6, signed: false)
    test = self()

    Req.Test.stub(Wikipedia, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      body = blocking_request(counts, test, :wikipedia, fn -> wikipedia_answer(conn) end)
      Req.Test.json(conn, body)
    end)

    Req.Test.stub(Wikidata, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      body = blocking_request(counts, test, :wikidata, fn -> wikidata_answer(conn) end)
      Req.Test.json(conn, body)
    end)

    assert %{interactive: 0, background: 0} = Wikimedia.stats()

    discoveries =
      for n <- 1..5 do
        Task.async(fn -> Discovery.run("vector search #{n}", sources: [Wikipedia]) end)
      end

    queries = ~w(knicks tokyo nvidia texas)
    for query <- queries, do: assert({:pending, _} = Entities.resolve(query, cache: cache))

    # Three requests get through; the rest wait for a slot.
    stubs = for _slot <- 1..3, do: next_stub()
    refute_receive {:in_stub, _source, _pid}, 100
    assert :atomics.get(counts, @in_flight) == 3

    assert %{waiting_interactive: interactive, waiting_background: background} =
             Wikimedia.stats()

    assert interactive + background > 0

    # From now on requests answer at once; release the ones that wait.
    :atomics.put(counts, @released, 1)
    Enum.each(stubs, &send(&1, :release))
    release_until_quiet()

    for {:ok, summary} <- Task.await_many(discoveries), do: assert(summary.ingested == 2)
    for query <- queries, do: assert(:ok = Entities.await(query, cache: cache))

    # 5 runs of a search and two pages, 4 lookups of a search and the details.
    assert :atomics.get(counts, @total) == 5 * 3 + 4 * 2
    assert :atomics.get(counts, @peak) == 3
    assert :atomics.get(counts, @wikipedia_peak) <= 2
    assert :atomics.get(counts, @in_flight) == 0
  end

  # Counts the request as in flight until it answers. Until the test sets
  # `@released`, it waits for `:release` from the test.
  defp blocking_request(counts, test, source, answer) do
    :atomics.add(counts, @total, 1)
    bump(counts, @in_flight, @peak)
    if source == :wikipedia, do: bump(counts, @wikipedia_in_flight, @wikipedia_peak)

    if :atomics.get(counts, @released) == 0 do
      send(test, {:in_stub, source, self()})

      receive do
        :release -> :ok
      end
    end

    if source == :wikipedia, do: :atomics.sub(counts, @wikipedia_in_flight, 1)
    :atomics.sub(counts, @in_flight, 1)
    answer.()
  end

  defp bump(counts, in_flight, peak) do
    now = :atomics.add_get(counts, in_flight, 1)
    raise_peak(counts, peak, now)
  end

  defp raise_peak(counts, peak, now) do
    old = :atomics.get(counts, peak)

    if now > old and :atomics.compare_exchange(counts, peak, old, now) != :ok,
      do: raise_peak(counts, peak, now)
  end

  defp next_stub do
    assert_receive {:in_stub, _source, pid}
    pid
  end

  defp release_until_quiet do
    receive do
      {:in_stub, _source, pid} ->
        send(pid, :release)
        release_until_quiet()
    after
      200 -> :ok
    end
  end

  defp wikipedia_answer(%{query_params: %{"list" => "search"}}),
    do: wikipedia_fixture("search.json")

  defp wikipedia_answer(%{query_params: %{"pageids" => id}}),
    do: wikipedia_fixture("page_#{id}.json")

  defp wikipedia_fixture(name),
    do: @wikipedia_fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp wikidata_answer(%{query_params: %{"action" => "wbsearchentities", "search" => query}}),
    do: wikidata_fixture("search_#{query}")

  defp wikidata_answer(%{query_params: %{"action" => "wbgetentities", "ids" => ids}}) do
    entities = ids |> String.split("|") |> Map.new(&{&1, wikidata_item(&1) || %{"missing" => ""}})
    %{"entities" => entities, "success" => 1}
  end
end
