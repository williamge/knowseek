defmodule Knowseek.CardsTest do
  # The ESPN stub runs in the cache's fetch tasks, so Req.Test is shared.
  use ExUnit.Case, async: false

  import Knowseek.Fixtures
  import Req.Test, only: [set_req_test_from_context: 1]

  alias Knowseek.Cache
  alias Knowseek.Cards
  alias Knowseek.Entities.{Entity, Wikidata}

  setup :set_req_test_from_context

  @start_ms 1_800_000_000_000

  setup do
    reset_espn_teams_cache()

    clock = start_supervised!({Agent, fn -> @start_ms end})
    now = fn -> Agent.get(clock, & &1) end
    cache = :"cards_cache_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, name: cache, clock: now})

    {:ok, clock: clock, now: now, opts: [cache: cache, clock: now]}
  end

  defp advance(clock, ms), do: Agent.update(clock, &(&1 + ms))

  defp knicks, do: team("New York Knicks")
  defp lakers, do: team("Los Angeles Lakers")

  defp team(label) do
    %Entity{id: "Q-" <> label, label: label, types: ["Q13393265"], leagues: ["Q155223"]}
  end

  # The requests the stub has seen so far. The stub sends its message before
  # it answers, and the callers wait for the answers, so by the time a fetch
  # is awaited the messages are in the mailbox: no waiting here.
  defp requests(acc \\ []) do
    receive do
      {:espn_request, path, _user_agent} -> requests([path | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp card_requests(paths), do: Enum.reject(paths, &(&1 == "/basketball/nba/teams"))

  # Answers the next `count` requests that the gated stub holds, however
  # long they take to arrive (a fetch asks the team list first, then the
  # schedule and the roster together). A request that never comes fails
  # the test after 5 s, it does not hang it.
  defp open_gate(count) do
    for _request <- 1..count do
      assert_receive {:espn_gated, upstream}, 5_000
      send(upstream, :go)
    end

    :ok
  end

  # A stub that records its requests and answers the team list, and every
  # other request with `respond`.
  defp stub_espn_failing(respond) do
    test = self()

    Req.Test.stub(Knowseek.Cards.Espn, fn conn ->
      send(test, {:espn_request, conn.request_path, []})

      if String.ends_with?(conn.request_path, "/teams") do
        Req.Test.json(conn, espn_fixture("teams"))
      else
        respond.(conn)
      end
    end)
  end

  describe "get/2: pending, then fresh" do
    test "a cold request returns :pending, and a later one returns the card with as_of", %{
      opts: opts
    } do
      stub_espn()

      assert %{
               status: :pending,
               type: nil,
               title: nil,
               facts: nil,
               as_of: nil,
               refresh_after_ms: 700
             } = Cards.get(knicks(), opts)

      :ok = Cards.await(knicks(), opts)

      assert %{
               status: :fresh,
               type: "sports_team",
               title: "New York Knicks",
               facts: %{record: "2-4"},
               as_of: as_of
             } = Cards.get(knicks(), opts)

      assert as_of == DateTime.from_unix!(@start_ms, :millisecond)
    end

    test "the request path never hits the network: the fetch runs in another process", %{
      opts: opts
    } do
      stub_espn(gate: true)

      assert %{status: :pending} = Cards.get(knicks(), opts)

      # The request returned while the upstream has not answered a thing.
      assert_receive {:espn_gated, upstream}, 5_000
      assert upstream != self()
      refute_received {:espn_request, "/basketball/nba/teams/18/schedule", _}

      # Still waiting for the upstream: the next request is :pending too.
      assert %{status: :pending} = Cards.get(knicks(), opts)

      send(upstream, :go)
      open_gate(2)
      :ok = Cards.await(knicks(), opts)
      assert %{status: :fresh} = Cards.get(knicks(), opts)
    end

    test "refresh_after_ms follows the time the card has left, clamped to 2-60 s", %{
      opts: opts,
      clock: clock
    } do
      stub_espn()
      Cards.get(lakers(), opts)
      :ok = Cards.await(lakers(), opts)

      # A game in progress is fresh for 15 s.
      assert %{status: :fresh, refresh_after_ms: 15_000} = Cards.get(lakers(), opts)

      advance(clock, 14_000)
      assert %{status: :fresh, refresh_after_ms: 2_000} = Cards.get(lakers(), opts)

      Cards.get(knicks(), opts)
      :ok = Cards.await(knicks(), opts)

      # A final or scheduled game is fresh for at least a minute.
      assert %{status: :fresh, refresh_after_ms: 60_000} = Cards.get(knicks(), opts)
    end
  end

  describe "get/2: single-flight" do
    test "many concurrent requests make one upstream fetch", %{opts: opts} do
      stub_espn(gate: true)
      entity = knicks()

      results =
        1..30
        |> Task.async_stream(fn _ -> Cards.get(entity, opts) end, max_concurrency: 30)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &(&1.status == :pending))

      assert_receive {:espn_gated, upstream}, 5_000
      send(upstream, :go)
      open_gate(2)
      :ok = Cards.await(entity, opts)

      assert %{status: :fresh} = Cards.get(entity, opts)

      # One schedule and one roster request, however many callers.
      assert Enum.sort(card_requests(requests())) == [
               "/basketball/nba/teams/18/roster",
               "/basketball/nba/teams/18/schedule"
             ]
    end

    test "requests while the card is fresh start no fetch", %{opts: opts} do
      stub_espn()
      Cards.get(knicks(), opts)
      :ok = Cards.await(knicks(), opts)
      _ = requests()

      for _ <- 1..10, do: assert(%{status: :fresh} = Cards.get(knicks(), opts))
      assert requests() == []
    end
  end

  describe "get/2: failures" do
    test "with nothing cached, a failure is :unavailable; the backoff stops new fetches", %{
      opts: opts,
      clock: clock
    } do
      stub_espn_failing(&Plug.Conn.send_resp(&1, 500, ""))

      assert %{status: :pending} = Cards.get(knicks(), opts)
      :ok = Cards.await(knicks(), opts)

      assert %{status: :unavailable, facts: nil, as_of: nil, refresh_after_ms: 30_000} =
               Cards.get(knicks(), opts)

      # Inside the backoff (10 s): no new upstream call, however many requests.
      assert requests() != []
      advance(clock, 5_000)
      for _ <- 1..10, do: assert(%{status: :unavailable} = Cards.get(knicks(), opts))
      assert requests() == []

      # After it: one more attempt.
      advance(clock, 5_001)
      assert %{status: :unavailable} = Cards.get(knicks(), opts)
      :ok = Cards.await(knicks(), opts)
      assert requests() != []
    end

    test "a failed refresh keeps the old card as :stale", %{opts: opts, clock: clock} do
      stub_espn()
      Cards.get(knicks(), opts)
      :ok = Cards.await(knicks(), opts)
      assert %{status: :fresh, as_of: as_of} = Cards.get(knicks(), opts)

      # The card has expired (it lasts at most six hours), and ESPN is down.
      Req.Test.stub(Knowseek.Cards.Espn, &Plug.Conn.send_resp(&1, 500, ""))
      advance(clock, :timer.hours(7))

      assert %{status: :stale, title: "New York Knicks", facts: %{record: "2-4"}} =
               Cards.get(knicks(), opts)

      :ok = Cards.await(knicks(), opts)

      assert %{status: :stale, as_of: ^as_of, facts: %{record: "2-4"}, refresh_after_ms: 2_000} =
               Cards.get(knicks(), opts)
    end

    test "an expired card is served stale while it refreshes, then fresh again", %{
      opts: opts,
      clock: clock
    } do
      stub_espn()
      Cards.get(lakers(), opts)
      :ok = Cards.await(lakers(), opts)

      advance(clock, 16_000)
      assert %{status: :stale} = Cards.get(lakers(), opts)
      :ok = Cards.await(lakers(), opts)

      assert %{status: :fresh, as_of: as_of} = Cards.get(lakers(), opts)
      assert as_of == DateTime.from_unix!(@start_ms + 16_000, :millisecond)
    end

    test "a 429 stops every card fetch for its Retry-After", %{opts: opts, clock: clock} do
      stub_espn_failing(fn conn ->
        conn |> Plug.Conn.put_resp_header("retry-after", "30") |> Plug.Conn.send_resp(429, "")
      end)

      Cards.get(knicks(), opts)
      :ok = Cards.await(knicks(), opts)
      assert %{status: :unavailable} = Cards.get(knicks(), opts)
      _ = requests()

      # Another team's card starts no fetch while the limit lasts.
      advance(clock, 29_000)
      assert %{status: :unavailable} = Cards.get(lakers(), opts)
      assert %{status: :unavailable} = Cards.get(knicks(), opts)
      assert requests() == []

      # It ends, and the upstream is asked again.
      stub_espn()
      advance(clock, 1_001)
      assert %{status: :pending} = Cards.get(lakers(), opts)
      :ok = Cards.await(lakers(), opts)
      assert %{status: :fresh} = Cards.get(lakers(), opts)
    end
  end

  describe "get/2: the cap on concurrent fetches" do
    test "at most max_in_flight cards are fetched at once", %{now: now} do
      cache = :"cards_capped_#{System.unique_integer([:positive])}"
      start_supervised!({Cache, name: cache, clock: now, max_in_flight: 1})
      opts = [cache: cache, clock: now]

      stub_espn(gate: true)

      assert %{status: :pending} = Cards.get(knicks(), opts)
      assert_receive {:espn_gated, upstream}, 5_000
      assert %{status: :pending} = Cards.get(lakers(), opts)
      _ = :sys.get_state(cache)

      # Only the Knicks' fetch runs: the Lakers' request was dropped.
      send(upstream, :go)
      open_gate(2)
      :ok = Cards.await(knicks(), opts)
      refute Enum.any?(requests(), &String.contains?(&1, "/teams/13/"))

      # With the slot free, the Lakers are fetched on the next request.
      assert %{status: :pending} = Cards.get(lakers(), opts)
      open_gate(2)
      :ok = Cards.await(lakers(), opts)
      assert %{status: :fresh} = Cards.get(lakers(), opts)
    end
  end

  describe "get/2: which entities have a card" do
    test "an entity no provider handles is :none, and nothing is fetched", %{opts: opts} do
      stub_wikidata()
      stub_espn()
      {:ok, candidates} = Wikidata.search("knicks", [])
      westchester = Enum.find(candidates, &(&1.label == "Westchester Knicks"))
      {:ok, [nvidia | _]} = Wikidata.search("nvidia", [])
      {:ok, [tokyo | _]} = Wikidata.search("tokyo", [])

      # A G League team, a company and a place.
      assert Cards.get(westchester, opts) == :none
      assert Cards.get(nvidia, opts) == :none
      assert Cards.get(tokyo, opts) == :none

      assert Cards.await(westchester, opts) == :ok
      assert requests() == []
    end

    test "providers come from the options (config in the application)", %{opts: opts} do
      assert Cards.get(knicks(), [providers: []] ++ opts) == :none
    end

    test "a place has a weather card only for the weather intent (ADR 0022)", %{opts: opts} do
      stub_wikidata()
      stub_open_meteo()
      {:ok, [tokyo | _]} = Wikidata.search("tokyo", [])

      assert Cards.get(tokyo, opts) == :none
      assert Cards.get(tokyo, [intent: nil] ++ opts) == :none
      assert Cards.await(tokyo, opts) == :ok
      refute_received {:open_meteo_request, _, _}

      assert %{status: :pending} = Cards.get(tokyo, [intent: :weather] ++ opts)
      :ok = Cards.await(tokyo, [intent: :weather] ++ opts)

      assert %{status: :fresh, type: "weather", title: "Tokyo", as_of: as_of} =
               Cards.get(tokyo, [intent: :weather] ++ opts)

      assert as_of == DateTime.from_unix!(@start_ms, :millisecond)
      assert_received {:open_meteo_request, %{"latitude" => "35.68944444444445"}, _}

      # The card is cached for the place, but a plain query still does not show it.
      assert Cards.get(tokyo, opts) == :none
    end

    test "the weather card is cached for 10 minutes", %{opts: opts, clock: clock} do
      stub_wikidata()
      stub_open_meteo()
      {:ok, [tokyo | _]} = Wikidata.search("tokyo", [])
      opts = [intent: :weather] ++ opts

      Cards.get(tokyo, opts)
      :ok = Cards.await(tokyo, opts)
      assert %{status: :fresh, refresh_after_ms: ms} = Cards.get(tokyo, opts)
      assert ms == 60_000

      advance(clock, :timer.minutes(10) - 1)
      assert %{status: :fresh} = Cards.get(tokyo, opts)
      advance(clock, 2)
      assert %{status: :stale} = Cards.get(tokyo, opts)
    end

    test "a provider without an intent handles the entity whatever the query said", %{opts: opts} do
      for intent <- [nil, :weather] do
        opts = [providers: [Knowseek.Cards.StaticProvider], intent: intent] ++ opts
        assert %{status: status} = Cards.get(knicks(), opts)
        assert status in [:pending, :fresh]
        :ok = Cards.await(knicks(), opts)
        assert %{status: :fresh, type: "sports_team"} = Cards.get(knicks(), opts)
      end
    end

    test "a team with the weather intent keeps the team card, not weather", %{opts: opts} do
      stub_espn()
      stub_open_meteo()
      opts = [intent: :weather] ++ opts

      assert %{status: :pending} = Cards.get(knicks(), opts)
      :ok = Cards.await(knicks(), opts)
      assert %{status: :fresh, type: "sports_team"} = Cards.get(knicks(), opts)
      refute_received {:open_meteo_request, _, _}
    end

    test "a provider that returns a malformed card is a failure, not a crash", %{opts: opts} do
      opts = [providers: [Knowseek.Cards.BadProvider]] ++ opts

      assert %{status: :pending} = Cards.get(knicks(), opts)
      :ok = Cards.await(knicks(), opts)
      assert %{status: :unavailable} = Cards.get(knicks(), opts)
    end
  end
end
