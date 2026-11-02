defmodule KnowseekWeb.CardControllerTest do
  # The Wikidata and ESPN stubs run in the caches' fetch tasks: shared Req.Test.
  use KnowseekWeb.ConnCase, async: false

  import Req.Test, only: [set_req_test_from_context: 1]

  alias Knowseek.{Cache, Cards, Entities}
  alias Knowseek.Entities.Wikidata

  setup :set_req_test_from_context

  @start_ms 1_800_000_000_000

  setup do
    reset_espn_teams_cache()

    clock = start_supervised!({Agent, fn -> @start_ms end})
    now = fn -> Agent.get(clock, & &1) end
    entities = :"card_entities_#{System.unique_integer([:positive])}"
    cards = :"card_cards_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, name: entities})
    start_supervised!({Cache, name: cards, clock: now})

    entity_options = [cache: entities]
    card_options = [cache: cards, clock: now]

    Application.put_env(:knowseek, KnowseekWeb.CardController,
      entities: entity_options,
      cards: card_options
    )

    on_exit(fn -> Application.delete_env(:knowseek, KnowseekWeb.CardController) end)

    stub_wikidata()
    stub_espn()
    stub_open_meteo()

    {:ok, clock: clock, entities: entity_options, cards: card_options}
  end

  defp card(conn, q) do
    conn |> get(~p"/api/cards", q: q) |> json_response(200) |> Map.fetch!("data")
  end

  # Waits for the entity fetch, then for the card fetch (if there is a card).
  defp settle(q, %{entities: entities, cards: cards}) do
    :ok = Entities.await(q, entities)

    with {:ok, %{entity: entity, intent: intent}} <- Entities.resolve(q, entities) do
      :ok = Cards.await(entity, [intent: intent] ++ cards)
    end

    :ok
  end

  defp stub_westchester_first do
    # "westchester knicks" finds the G League team first (the recorded search
    # for "knicks" lists it last).
    search = wikidata_fixture("search_knicks")
    {westchester, others} = Enum.split_with(search["search"], &(&1["id"] == "Q15927936"))
    reordered = %{search | "search" => westchester ++ others}
    details = wikidata_fixture("entities_knicks")

    Req.Test.stub(Wikidata, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.query_params do
        %{"action" => "wbsearchentities"} ->
          Req.Test.json(conn, reordered)

        %{"action" => "wbgetentities", "ids" => ids} ->
          entities = Map.take(details["entities"], String.split(ids, "|"))
          Req.Test.json(conn, %{"success" => 1, "entities" => entities})
      end
    end)
  end

  describe "GET /api/cards: pending, then fresh" do
    test "a cold query is pending with nothing else", %{conn: conn} do
      assert %{
               "status" => "pending",
               "entity" => nil,
               "alternatives" => [],
               "card" => nil,
               "as_of" => nil,
               "refresh_after_ms" => 700
             } = card(conn, "knicks")
    end

    test "the request path calls neither Wikidata nor ESPN", %{conn: conn} do
      test = self()

      Req.Test.stub(Wikidata, fn conn ->
        send(test, {:wikidata_gated, self()})

        receive do
          :go -> :ok
        end

        Req.Test.json(conn, %{"success" => 1, "search" => []})
      end)

      assert %{"status" => "pending"} = card(conn, "knicks")

      # The response came back while Wikidata had not answered.
      assert_receive {:wikidata_gated, wikidata}
      refute_received {:espn_request, _, _}
      send(wikidata, :go)
    end

    test "knicks: pending until the entity and the card are cached, then fresh", %{
      conn: conn,
      entities: entities,
      cards: cards
    } do
      assert %{"status" => "pending", "entity" => nil} = card(conn, "knicks")

      # The entity is cached; the card fetch starts with the next request.
      :ok = Entities.await("knicks", entities)

      assert %{"status" => "pending", "card" => nil, "entity" => entity, "alternatives" => alts} =
               card(conn, "knicks")

      assert entity == %{
               "id" => "Q131364",
               "label" => "New York Knicks",
               "description" => "National Basketball Association team in New York City",
               "kind" => "sports_team",
               "wikipedia_title" => "New York Knicks"
             }

      assert [%{"id" => "Q15927936", "label" => "Westchester Knicks", "kind" => "sports_team"}] =
               alts

      {:ok, %{entity: entity}} = Entities.resolve("knicks", entities)
      :ok = Cards.await(entity, cards)

      assert %{
               "status" => "fresh",
               "card" => %{
                 "type" => "sports_team",
                 "title" => "New York Knicks",
                 "facts" => facts
               },
               "as_of" => as_of,
               "refresh_after_ms" => refresh_after_ms
             } = card(conn, "knicks")

      assert {:ok, _datetime, 0} = DateTime.from_iso8601(as_of)
      assert refresh_after_ms in 2_000..60_000

      assert %{
               "source" => "ESPN",
               "league" => "NBA",
               "record" => "2-4",
               "live" => nil,
               "last_game" => %{"result" => "L", "opponent" => "Philadelphia 76ers"},
               "next_game" => %{"opponent" => "Brooklyn Nets", "home_away" => "home"},
               "injuries" => [%{"player" => "Jose Alvarado", "status" => "Out"}]
             } = facts

      assert {:ok, _datetime, 0} = DateTime.from_iso8601(facts["next_game"]["date"])
    end

    test "queries that differ in case and spacing are the same card", %{conn: conn} = context do
      card(conn, "knicks")
      settle("knicks", context)
      card(conn, "knicks")
      settle("knicks", context)

      assert %{"status" => "fresh", "entity" => %{"id" => "Q131364"}} = card(conn, "  KNICKS ")
    end
  end

  describe "GET /api/cards: stale and unavailable" do
    test "past its TTL with ESPN down, the card is stale and says since when",
         %{
           conn: conn,
           clock: clock
         } = context do
      card(conn, "knicks")
      settle("knicks", context)
      card(conn, "knicks")
      settle("knicks", context)
      assert %{"status" => "fresh", "as_of" => as_of} = card(conn, "knicks")

      Req.Test.stub(Knowseek.Cards.Espn, &Plug.Conn.send_resp(&1, 500, ""))
      Agent.update(clock, &(&1 + :timer.hours(7)))

      assert %{"status" => "stale", "card" => %{"title" => "New York Knicks"}, "as_of" => ^as_of} =
               card(conn, "knicks")

      settle("knicks", context)

      assert %{
               "status" => "stale",
               "as_of" => ^as_of,
               "refresh_after_ms" => 2_000,
               "card" => %{"facts" => %{"record" => "2-4"}}
             } = card(conn, "knicks")
    end

    test "a failing ESPN with nothing cached is unavailable, with the entity",
         %{conn: conn} = context do
      Req.Test.stub(Knowseek.Cards.Espn, &Plug.Conn.send_resp(&1, 500, ""))

      card(conn, "knicks")
      settle("knicks", context)
      card(conn, "knicks")
      settle("knicks", context)

      assert %{
               "status" => "unavailable",
               "entity" => %{"id" => "Q131364"},
               "card" => nil,
               "as_of" => nil,
               "refresh_after_ms" => 30_000
             } = card(conn, "knicks")
    end

    test "a failing Wikidata with nothing cached is unavailable", %{conn: conn} = context do
      Req.Test.stub(Wikidata, &Plug.Conn.send_resp(&1, 503, ""))

      card(conn, "knicks")
      settle("knicks", context)

      assert %{"status" => "unavailable", "entity" => nil, "card" => nil} = card(conn, "knicks")
    end

    test "a Wikidata rate limit is unavailable and starts no more Wikidata calls",
         %{conn: conn} = context do
      test = self()

      Req.Test.stub(Wikidata, fn conn ->
        send(test, {:wikidata_request, "429", %{}, []})
        conn |> Plug.Conn.put_resp_header("retry-after", "30") |> Plug.Conn.send_resp(429, "")
      end)

      card(conn, "knicks")
      settle("knicks", context)
      assert %{"status" => "unavailable"} = card(conn, "knicks")
      assert_received {:wikidata_request, "429", _, _}

      for q <- ["lakers", "celtics", "nvidia"] do
        assert %{"status" => "unavailable"} = card(conn, q)
      end

      refute_received {:wikidata_request, _, _, _}
    end
  end

  describe "GET /api/cards: weather" do
    # The entity is fetched by the first request, the card by the second.
    defp settled_card(conn, q, context) do
      card(conn, q)
      settle(q, context)
      card(conn, q)
      settle(q, context)
      card(conn, q)
    end

    test "weather in tokyo: pending, then a fresh weather card with the place",
         %{conn: conn} =
           context do
      assert %{"status" => "pending", "entity" => nil} = card(conn, "weather in tokyo")
      settle("weather in tokyo", context)

      assert %{"status" => "pending", "card" => nil, "entity" => %{"id" => "Q1490"}} =
               card(conn, "weather in tokyo")

      settle("weather in tokyo", context)

      assert %{
               "status" => "fresh",
               "entity" => %{"id" => "Q1490", "label" => "Tokyo", "kind" => "place"},
               "card" => %{"type" => "weather", "title" => "Tokyo", "facts" => facts},
               "as_of" => as_of,
               "refresh_after_ms" => refresh_after_ms
             } = card(conn, "weather in tokyo")

      assert {:ok, _datetime, 0} = DateTime.from_iso8601(as_of)
      assert refresh_after_ms in 2_000..60_000

      assert %{
               "source" => "Open-Meteo.com",
               "timezone" => "Asia/Tokyo",
               "utc_offset_seconds" => 32_400,
               "observed_at" => "2026-11-01T01:00:00Z",
               "current" => %{
                 "temperature_c" => 17.0,
                 "apparent_temperature_c" => 15.7,
                 "condition" => "Clear sky",
                 "wind_speed_kmh" => 4.7
               },
               "daily" => [%{"date" => "2026-11-01", "high_c" => 19.9} | _]
             } = facts

      assert_received {:open_meteo_request, %{"latitude" => "35.68944444444445"} = params, _}
      assert params["longitude"] == "139.69166666666666"
    end

    test "tokyo weather is the same card, from the same entity", %{conn: conn} = context do
      assert %{"status" => "fresh", "card" => %{"type" => "weather", "title" => "Tokyo"}} =
               settled_card(conn, "tokyo weather", context)

      # One entity lookup and one forecast serve both shapes of the query.
      assert %{"status" => "fresh", "card" => %{"type" => "weather"}} =
               card(conn, "Weather in  TOKYO")
    end

    test "weather in texas: a state is a place with one point", %{conn: conn} = context do
      assert %{
               "status" => "fresh",
               "entity" => %{"id" => "Q1439", "kind" => "place"},
               "card" => %{"type" => "weather", "title" => "Texas"}
             } = settled_card(conn, "weather in texas", context)

      assert_received {:open_meteo_request, %{"latitude" => "31", "longitude" => "-100"}, _}
    end

    test "a team with the weather intent gets its team card, not weather",
         %{conn: conn} =
           context do
      assert %{
               "status" => "fresh",
               "entity" => %{"id" => "Q131364", "kind" => "sports_team"},
               "card" => %{"type" => "sports_team", "title" => "New York Knicks"}
             } = settled_card(conn, "knicks weather", context)

      refute_received {:open_meteo_request, _, _}
    end

    test "a company with the weather intent has no card", %{conn: conn} = context do
      card(conn, "weather in nvda")
      settle("weather in nvda", context)

      assert %{"status" => "none", "card" => nil} = card(conn, "weather in nvda")
      refute_received {:open_meteo_request, _, _}
    end

    test "an Open-Meteo rate limit with nothing cached is unavailable", %{conn: conn} = context do
      stub_open_meteo(&Plug.Conn.send_resp(&1, 429, ""))

      assert %{"status" => "unavailable", "entity" => %{"id" => "Q1490"}, "card" => nil} =
               settled_card(conn, "weather in tokyo", context)
    end

    test "a malformed Open-Meteo answer with nothing cached is unavailable",
         %{conn: conn} = context do
      stub_open_meteo(%{"current" => "rain"})

      assert %{"status" => "unavailable", "card" => nil, "refresh_after_ms" => 30_000} =
               settled_card(conn, "weather in tokyo", context)
    end

    test "past its TTL with Open-Meteo down, the weather card is stale",
         %{
           conn: conn,
           clock: clock
         } = context do
      assert %{"status" => "fresh", "as_of" => as_of} =
               settled_card(conn, "weather in tokyo", context)

      stub_open_meteo(&Plug.Conn.send_resp(&1, 500, ""))
      Agent.update(clock, &(&1 + :timer.minutes(11)))

      assert %{"status" => "stale", "as_of" => ^as_of, "card" => %{"type" => "weather"}} =
               card(conn, "weather in tokyo")

      settle("weather in tokyo", context)

      assert %{"status" => "stale", "as_of" => ^as_of, "refresh_after_ms" => 2_000} =
               card(conn, "weather in tokyo")
    end
  end

  describe "GET /api/cards: none" do
    test "the Westchester Knicks have no card (NBA G League)", %{conn: conn} = context do
      stub_westchester_first()

      card(conn, "westchester knicks")
      settle("westchester knicks", context)

      assert %{"status" => "none", "entity" => nil, "alternatives" => [], "card" => nil} =
               card(conn, "westchester knicks")

      # No ESPN request for it.
      refute_received {:espn_request, _, _}
    end

    test "a company has no card yet", %{conn: conn} = context do
      card(conn, "nvda")
      settle("nvda", context)

      assert %{"status" => "none", "card" => nil} = card(conn, "nvda")
      refute_received {:espn_request, _, _}
    end

    test "a place alone is a search, not a weather question: no card, no weather call",
         %{conn: conn} = context do
      card(conn, "tokyo")
      settle("tokyo", context)

      assert %{"status" => "none", "entity" => nil, "card" => nil} = card(conn, "tokyo")
      refute_received {:open_meteo_request, _, _}
    end

    test "a query that names nothing is none", %{conn: conn} = context do
      card(conn, "zzzz qqqq")
      settle("zzzz qqqq", context)

      assert %{"status" => "none"} = card(conn, "zzzz qqqq")
    end

    test "junk is none, with no error and no upstream call", %{conn: conn} do
      # Not names (too long, control characters, 200 combining marks in a row).
      for q <- [
            String.duplicate("x", 5_000),
            "a\u0000b",
            String.duplicate("\u0301", 200) <> "a"
          ] do
        assert %{"status" => "none", "entity" => nil, "card" => nil} = card(conn, q)
      end

      refute_received {:espn_request, _, _}
    end

    test "other odd text is answered, not crashed on", %{conn: conn} = context do
      for q <- ["%%%", "💥💥💥", "' OR 1=1 --", "<script>alert(1)</script>"] do
        assert %{"status" => "pending"} = card(conn, q)
        settle(q, context)
        assert %{"status" => "none"} = card(conn, q)
      end
    end
  end

  describe "GET /api/cards: alternatives" do
    test "one with the label of the top entity is dropped (two items, one label)", %{
      conn: conn,
      entities: entities,
      cards: cards
    } do
      entities = [resolver: Knowseek.Entities.FakeResolver] ++ entities
      cards = [providers: [Knowseek.Cards.StaticProvider]] ++ cards
      Application.put_env(:knowseek, KnowseekWeb.CardController, entities: entities, cards: cards)
      context = %{entities: entities, cards: cards}

      card(conn, "dup")
      settle("dup", context)
      card(conn, "dup")
      settle("dup", context)

      assert %{"status" => "fresh", "entity" => %{"id" => "Q-1"}, "alternatives" => alternatives} =
               card(conn, "dup")

      # "Same name " has the label of the top entity ("Same Name"); "Other Name" does not.
      assert Enum.map(alternatives, & &1["id"]) == ["Q-3"]
    end
  end

  describe "GET /api/cards: bad requests" do
    test "q is required", %{conn: conn} do
      assert %{"errors" => %{"detail" => "q is required"}} =
               conn |> get(~p"/api/cards") |> json_response(400)

      assert conn |> get(~p"/api/cards", q: "   ") |> json_response(400)
      assert conn |> get("/api/cards?q[]=knicks") |> json_response(400)
      assert conn |> get("/api/cards?q[a]=knicks") |> json_response(400)
    end
  end
end
