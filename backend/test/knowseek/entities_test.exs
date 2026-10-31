defmodule Knowseek.EntitiesTest do
  # The Wikidata stub runs in the cache's fetch task, so Req.Test is shared.
  use ExUnit.Case, async: false

  import Knowseek.Fixtures
  import Req.Test, only: [set_req_test_from_context: 1]

  alias Knowseek.Cache
  alias Knowseek.Entities
  alias Knowseek.Entities.{Entity, FakeResolver, Wikidata}

  setup :set_req_test_from_context

  setup do
    cache = :"entities_cache_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, name: cache})
    stub_wikidata()
    {:ok, cache: cache}
  end

  # Resolves `query`: the cold call, then the call after the fetch finished.
  defp resolve_when_ready(query, opts) do
    assert {:pending, ^query} = Entities.resolve(query, opts)
    :ok = Entities.await(query, opts)
    Entities.resolve(query, opts)
  end

  defp ids(entities), do: Enum.map(entities, & &1.id)

  defp drain_requests(acc \\ []) do
    receive do
      {:wikidata_request, action, params, _user_agent} ->
        drain_requests([{action, params} | acc])
    after
      20 -> Enum.reverse(acc)
    end
  end

  describe "resolve/2 acceptance cases" do
    test "knicks resolves to Q131364 with the other teams as alternatives", %{cache: cache} do
      assert {:ok, %{intent: nil, entity: entity, alternatives: alternatives}} =
               resolve_when_ready("knicks", cache: cache)

      assert entity.id == "Q131364"
      assert entity.label == "New York Knicks"
      assert entity.wikipedia_title == "New York Knicks"
      assert entity.sitelinks == 74
      assert entity.types == ["Q13393265"]

      # The album, the horse, the rivalries and the nature reserve are not teams.
      assert ids(alternatives) == ["Q15927936"]
      assert hd(alternatives).label == "Westchester Knicks"
    end

    test "weather in tokyo has the weather intent and the Tokyo entity with coordinates", %{
      cache: cache
    } do
      assert {:ok, %{intent: :weather, entity: tokyo, alternatives: alternatives}} =
               resolve_when_ready("weather in tokyo", cache: cache)

      assert tokyo.id == "Q1490"
      assert tokyo.coordinates == %{latitude: 35.68944444444445, longitude: 139.69166666666666}

      # Only the place was searched: `weather in tokyo` finds nothing in Wikidata.
      assert [{"wbsearchentities", %{"search" => "tokyo"}}, {"wbgetentities", _}] =
               drain_requests()

      # The special wards are a place too. The university and Sony are not.
      assert ids(alternatives) == ["Q7473516"]
    end

    test "tokyo weather has the same result", %{cache: cache} do
      assert {:ok, %{intent: :weather, entity: %{id: "Q1490"}}} =
               resolve_when_ready("tokyo weather", cache: cache)
    end

    test "weather in texas and weather in japan resolve a state and a country", %{cache: cache} do
      assert {:ok, %{intent: :weather, entity: texas}} =
               resolve_when_ready("weather in texas", cache: cache)

      assert texas.id == "Q1439"
      assert Entities.kind(texas) == :place

      assert {:ok, %{intent: :weather, entity: japan}} =
               resolve_when_ready("weather in japan", cache: cache)

      assert japan.id == "Q17"
      assert Entities.kind(japan) == :place
    end

    test "apple resolves to the company, not the fruit or the record label", %{cache: cache} do
      assert {:ok, %{entity: apple, alternatives: []}} = resolve_when_ready("apple", cache: cache)

      assert apple.id == "Q312"
      assert apple.exchange_tickers == [%{exchange: "Q82059", ticker: "AAPL"}]
    end

    test "a weather query about a team has the intent, so consumers check the kind", %{
      cache: cache
    } do
      assert {:ok, %{intent: :weather, entity: knicks}} =
               resolve_when_ready("knicks weather", cache: cache)

      assert knicks.id == "Q131364"
      assert Entities.kind(knicks) == :sports_team
    end

    test "nvidia resolves with the NVDA ticker from the P414 and P249 qualifier", %{cache: cache} do
      assert {:ok, %{intent: nil, entity: nvidia, alternatives: []}} =
               resolve_when_ready("nvidia", cache: cache)

      assert nvidia.id == "Q182477"
      assert nvidia.exchange_tickers == [%{exchange: "Q82059", ticker: "NVDA"}]
    end

    test "nvda skips the screen reader that the search puts first", %{cache: cache} do
      assert {:ok, %{entity: entity, alternatives: []}} = resolve_when_ready("nvda", cache: cache)

      assert entity.id == "Q182477"
      assert entity.label == "Nvidia"
    end

    test "a query with no match is :none", %{cache: cache} do
      assert resolve_when_ready("zzzz", cache: cache) == :none
    end

    test "a query whose candidates have no supported type is :none", %{cache: cache} do
      Req.Test.stub(Wikidata, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["action"] do
          "wbsearchentities" ->
            Req.Test.json(conn, %{"search" => [%{"id" => "Q1116614", "label" => "NVDA"}]})

          "wbgetentities" ->
            Req.Test.json(conn, %{"entities" => %{"Q1116614" => wikidata_item("Q1116614")}})
        end
      end)

      assert resolve_when_ready("screen reader", cache: cache) == :none
    end
  end

  describe "resolve/2 caching" do
    test "a cold call returns {:pending, query} without calling Wikidata itself", %{cache: cache} do
      test = self()

      Req.Test.stub(Wikidata, fn conn ->
        send(test, {:in_stub, self()})

        receive do
          :release -> Req.Test.json(conn, %{"search" => []})
        end
      end)

      assert Entities.resolve("knicks", cache: cache) == {:pending, "knicks"}

      # The fetch is running in another process, and the caller did not wait for it.
      assert_receive {:in_stub, stub_pid}
      assert stub_pid != self()
      assert Entities.resolve("knicks", cache: cache) == {:pending, "knicks"}

      send(stub_pid, :release)
      :ok = Entities.await("knicks", cache: cache)
      assert Entities.resolve("knicks", cache: cache) == :none
    end

    test "a later call returns the entity, and a second identical call makes no new request", %{
      cache: cache
    } do
      assert {:ok, %{entity: %{id: "Q131364"}}} = resolve_when_ready("knicks", cache: cache)
      assert [{"wbsearchentities", _}, {"wbgetentities", _}] = drain_requests()

      assert {:ok, %{entity: %{id: "Q131364"}}} = Entities.resolve("knicks", cache: cache)
      assert drain_requests() == []
    end

    test "case, spacing and the intent word do not make a new entry", %{cache: cache} do
      assert {:ok, %{intent: nil, entity: %{id: "Q1490"}}} =
               resolve_when_ready("tokyo", cache: cache)

      drain_requests()

      assert {:ok, %{intent: :weather, entity: %{id: "Q1490"}}} =
               Entities.resolve("Weather in  TOKYO", cache: cache)

      assert drain_requests() == []
    end

    test "an empty answer is cached too", %{cache: cache} do
      assert resolve_when_ready("zzzz", cache: cache) == :none
      assert [{"wbsearchentities", _}] = drain_requests()

      assert Entities.resolve("zzzz", cache: cache) == :none
      assert drain_requests() == []
    end

    test "a blank or very long query is :none without a request", %{cache: cache} do
      assert Entities.resolve("", cache: cache) == :none
      assert Entities.resolve("   ", cache: cache) == :none
      assert Entities.resolve(String.duplicate("knicks ", 30), cache: cache) == :none

      assert drain_requests() == []
    end
  end

  describe "resolve/2 failures" do
    test "an HTTP 429 is {:error, _}, and is not retried during the backoff", %{cache: cache} do
      Req.Test.stub(Wikidata, &Plug.Conn.send_resp(&1, 429, "Too Many Requests"))

      assert resolve_when_ready("knicks", cache: cache) == {:error, {:http_status, 429}}

      # Back on, but the failure is remembered for the backoff.
      stub_wikidata()
      assert Entities.resolve("knicks", cache: cache) == {:error, {:http_status, 429}}
      assert drain_requests() == []
    end

    test "a timeout is {:error, _}", %{cache: cache} do
      Req.Test.stub(Wikidata, &Req.Test.transport_error(&1, :timeout))

      assert {:error, %Req.TransportError{reason: :timeout}} =
               resolve_when_ready("knicks", cache: cache)
    end

    test "a failure on one query does not affect another", %{cache: cache} do
      Req.Test.stub(Wikidata, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        if conn.query_params["search"] == "knicks" do
          Plug.Conn.send_resp(conn, 500, "oops")
        else
          Req.Test.json(conn, %{"search" => []})
        end
      end)

      assert resolve_when_ready("knicks", cache: cache) == {:error, {:http_status, 500}}
      assert resolve_when_ready("zzzz", cache: cache) == :none
    end
  end

  describe "resolve/2 resolver option" do
    test "uses the given resolver module", %{cache: cache} do
      opts = [cache: cache, resolver: FakeResolver]

      assert {:ok, %{entity: %Entity{id: "Q-fake"}, alternatives: []}} =
               resolve_when_ready("fake", opts)

      assert resolve_when_ready("other", opts) == :none
      assert resolve_when_ready("boom", opts) == {:error, :boom}
      assert drain_requests() == []
    end
  end

  describe "resolve/2 stale answers" do
    setup do
      clock = start_supervised!({Agent, fn -> 1_800_000_000_000 end})
      cache = :"entities_stale_cache_#{System.unique_integer([:positive])}"
      start_supervised!({Cache, name: cache, clock: fn -> Agent.get(clock, & &1) end})

      # Past the one-day TTL.
      expire = fn -> Agent.update(clock, &(&1 + :timer.hours(25))) end
      {:ok, stale_cache: cache, expire: expire}
    end

    test "an expired answer is returned while it refreshes", %{stale_cache: cache, expire: expire} do
      assert {:ok, %{entity: %{id: "Q131364"}}} = resolve_when_ready("knicks", cache: cache)
      drain_requests()
      expire.()

      test = self()

      Req.Test.stub(Wikidata, fn conn ->
        send(test, {:in_stub, self()})

        receive do
          :release -> Req.Test.json(conn, %{"search" => []})
        end
      end)

      # The old answer comes back at once, and a refresh starts in the background.
      assert {:ok, %{entity: %{id: "Q131364"}}} = Entities.resolve("knicks", cache: cache)
      assert_receive {:in_stub, stub_pid}
      assert {:ok, %{entity: %{id: "Q131364"}}} = Entities.resolve("knicks", cache: cache)

      send(stub_pid, :release)
      :ok = Entities.await("knicks", cache: cache)

      # The refreshed answer is "nothing matches", and is fresh.
      assert Entities.resolve("knicks", cache: cache) == :none
    end

    test "a failed refresh keeps the old answer", %{stale_cache: cache, expire: expire} do
      assert {:ok, %{entity: %{id: "Q131364"}}} = resolve_when_ready("knicks", cache: cache)
      drain_requests()
      expire.()

      Req.Test.stub(Wikidata, &Plug.Conn.send_resp(&1, 429, "Too Many Requests"))

      assert {:ok, %{entity: %{id: "Q131364"}}} = Entities.resolve("knicks", cache: cache)
      :ok = Entities.await("knicks", cache: cache)

      assert {:ok, %{entity: %{id: "Q131364"}}} = Entities.resolve("knicks", cache: cache)

      # The backoff stops a new request.
      stub_wikidata()
      assert {:ok, %{entity: %{id: "Q131364"}}} = Entities.resolve("knicks", cache: cache)
      assert drain_requests() == []
    end
  end

  describe "await/2" do
    test "returns :ok when nothing is running or the query is blank", %{cache: cache} do
      assert Entities.await("knicks", cache: cache) == :ok
      assert Entities.await("  ", cache: cache) == :ok
    end
  end

  describe "choose/1" do
    defp team(id), do: %Entity{id: id, types: ["Q13393265"]}

    test "takes the first candidate with a kind, not the first candidate" do
      screen_reader = %Entity{id: "Q1", types: ["Q1328864"]}

      company = %Entity{
        id: "Q2",
        types: ["Q891723"],
        exchange_tickers: [%{exchange: "Q3", ticker: "X"}]
      }

      assert {:ok, %{entity: ^company, alternatives: []}} =
               Entities.choose([screen_reader, company])
    end

    test "alternatives are the other candidates of the same kind, in order, at most 5" do
      album = %Entity{id: "Q-album", types: ["Q482994"]}

      company = %Entity{
        id: "Q-co",
        types: ["Q891723"],
        exchange_tickers: [%{exchange: "Q3", ticker: "X"}]
      }

      teams = Enum.map(1..8, &team("Q-team-#{&1}"))

      assert {:ok, %{entity: top, alternatives: alternatives}} =
               Entities.choose([album, hd(teams), company | tl(teams)])

      assert top.id == "Q-team-1"
      assert ids(alternatives) == ["Q-team-2", "Q-team-3", "Q-team-4", "Q-team-5", "Q-team-6"]
    end

    test "is :none without a candidate with a kind, and for no candidates" do
      assert Entities.choose([]) == :none
      assert Entities.choose([%Entity{id: "Q1", types: ["Q5"]}]) == :none
    end
  end

  describe "kind/1" do
    test "a team type is a sports team" do
      assert Entities.kind(team("Q1")) == :sports_team
      assert Entities.kind(%Entity{id: "Q1", types: ["Q5", "Q476028"]}) == :sports_team
    end

    test "a company type needs an exchange ticker" do
      ticker = [%{exchange: "Q82059", ticker: "NVDA"}]

      assert Entities.kind(%Entity{id: "Q1", types: ["Q891723"], exchange_tickers: ticker}) ==
               :company

      assert Entities.kind(%Entity{id: "Q1", types: ["Q891723"]}) == nil
    end

    test "a place type needs coordinates" do
      point = %{latitude: 1.0, longitude: 2.0}
      assert Entities.kind(%Entity{id: "Q1", types: ["Q1549591"], coordinates: point}) == :place
      assert Entities.kind(%Entity{id: "Q1", types: ["Q1549591"]}) == nil
    end

    test "coordinates alone do not make a place" do
      point = %{latitude: 1.0, longitude: 2.0}
      assert Entities.kind(%Entity{id: "Q1", types: ["Q3918"], coordinates: point}) == nil
    end

    test "an unsupported type has no kind" do
      assert Entities.kind(%Entity{id: "Q1", types: ["Q1328864"]}) == nil
      assert Entities.kind(%Entity{id: "Q1", types: []}) == nil
    end
  end
end
