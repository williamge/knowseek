defmodule Knowseek.Cards.Providers.NbaTest do
  # The balldontlie stub runs in the team list cache's task, so Req.Test is shared.
  use ExUnit.Case, async: false

  import Knowseek.Fixtures
  import Req.Test, only: [set_req_test_from_context: 1]

  alias Knowseek.Cards.Balldontlie
  alias Knowseek.Cards.Providers.Nba
  alias Knowseek.Entities.{Entity, Wikidata}

  setup :set_req_test_from_context

  setup do
    # The team list is cached for a day in the application's cache: start
    # every test with it empty, so that each one sees its own requests.
    reset_nba_teams_cache()
  end

  defp team(label, attrs \\ []) do
    struct!(
      %Entity{id: "Q-" <> label, label: label, types: ["Q13393265"], leagues: ["Q155223"]},
      attrs
    )
  end

  defp requests(acc \\ []) do
    receive do
      {:nba_request, request, _headers} -> requests([request | acc])
    after
      20 -> Enum.reverse(acc)
    end
  end

  defp knicks_games, do: nba_fixture("games_nyk")["data"]
  defp lakers_games, do: nba_fixture("games_lal_live")["data"]

  # A final game of the Knicks (20) against the Nets (3), with `attrs` over it.
  defp final(knicks, nets, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => System.unique_integer([:positive]),
        "datetime" => "2026-12-01T00:30:00.000Z",
        "status" => "Final",
        "status_state" => "final",
        "period" => 4,
        "time" => "Final",
        "postseason" => false,
        "ist_stage" => nil,
        "home_team_score" => knicks,
        "visitor_team_score" => nets,
        "home_team" => %{"id" => 20, "full_name" => "New York Knicks"},
        "visitor_team" => %{"id" => 3, "full_name" => "Brooklyn Nets"}
      },
      attrs
    )
  end

  # Runs `fun` with the balldontlie config `api_key` set to `key`.
  defp with_key(key, fun) do
    previous = Application.fetch_env!(:knowseek, Balldontlie)
    Application.put_env(:knowseek, Balldontlie, Keyword.put(previous, :api_key, key))

    try do
      fun.()
    after
      Application.put_env(:knowseek, Balldontlie, previous)
    end
  end

  describe "handles?/1" do
    test "an NBA team" do
      assert Nba.handles?(team("New York Knicks"))
    end

    test "the Westchester Knicks play in the G League, not the NBA" do
      stub_wikidata()
      assert {:ok, candidates} = Wikidata.search("knicks", [])

      westchester = Enum.find(candidates, &(&1.label == "Westchester Knicks"))
      knicks = Enum.find(candidates, &(&1.label == "New York Knicks"))

      assert westchester.leagues == ["Q842793"]
      refute Nba.handles?(westchester)
      assert Nba.handles?(knicks)
    end

    test "a team with no current NBA league is not handled (a defunct team of the same name)" do
      refute Nba.handles?(team("Denver Nuggets", leagues: []))
      refute Nba.handles?(team("Denver Nuggets", leagues: ["Q1429493"]))
    end

    test "an NBA league alone is not enough: the entity must be a sports team" do
      refute Nba.handles?(team("Some Game", types: ["Q18431960"]))
    end

    test "a company is not handled" do
      stub_wikidata()
      assert {:ok, [nvidia | _]} = Wikidata.search("nvidia", [])
      refute Nba.handles?(nvidia)
    end

    test "without an API key no team is handled, so there is no card" do
      for key <- [nil, "", "   "] do
        with_key(key, fn ->
          refute Balldontlie.configured?()
          refute Nba.handles?(team("New York Knicks"))
        end)
      end

      assert Nba.handles?(team("New York Knicks"))
    end
  end

  describe "facts/2 and ttl/2" do
    test "a team between games: record, last game, next game" do
      facts = Nba.facts(20, knicks_games())

      assert facts.source == "balldontlie"
      assert facts.league == "NBA"
      assert facts.record == "2-4"
      assert facts.live == nil

      assert facts.last_game == %{
               date: ~U[2026-10-30 23:30:00Z],
               opponent: "Philadelphia 76ers",
               home_away: "away",
               result: "L",
               team_score: 93,
               opponent_score: 98
             }

      # The postponed game of 2026-11-01 is neither played nor next.
      assert facts.next_game == %{
               date: ~U[2026-11-03 00:30:00Z],
               opponent: "Brooklyn Nets",
               home_away: "home"
             }

      refute Map.has_key?(facts, :injuries)
    end

    test "a game in progress: score, period and clock, and the one before it" do
      facts = Nba.facts(14, lakers_games())

      assert facts.record == "1-1"

      assert facts.live == %{
               opponent: "Golden State Warriors",
               home_away: "away",
               team_score: 80,
               opponent_score: 85,
               period: 3,
               clock: "4:32",
               status_text: "3rd Qtr 4:32"
             }

      assert facts.last_game.date == ~U[2026-10-29 02:30:00Z]
      assert facts.last_game.result == "L"
      assert facts.next_game.date == ~U[2026-11-02 02:00:00Z]
    end

    test "at halftime there is no clock, and the status says so" do
      games =
        Enum.map(lakers_games(), fn
          %{"status_state" => "in_progress"} = game ->
            %{game | "status" => "Halftime", "time" => " "}

          game ->
            game
        end)

      assert %{clock: nil, status_text: "Halftime", period: 3} = Nba.facts(14, games).live
    end

    test "no games is a card with empty fields" do
      assert %{record: nil, live: nil, last_game: nil, next_game: nil} = Nba.facts(20, [])
    end

    test "the record counts regular-season finals: NBA Cup games, but not the Cup final or playoffs" do
      games = [
        final(110, 100),
        final(100, 110, %{"ist_stage" => "East Group A"}),
        final(120, 100, %{"ist_stage" => "East Quarterfinal"}),
        final(90, 100, %{"ist_stage" => "Championship"}),
        final(100, 90, %{"postseason" => true})
      ]

      assert Nba.facts(20, games).record == "2-1"
    end

    test "without status_state the status and the period tell the state" do
      games =
        Enum.map(lakers_games(), &Map.delete(&1, "status_state")) ++
          [final(1, 2, %{"status_state" => nil, "postponed" => true})]

      facts = Nba.facts(14, games)

      assert facts.record == "1-1"
      assert facts.live.status_text == "3rd Qtr 4:32"
      assert facts.next_game.date == ~U[2026-11-02 02:00:00Z]
    end

    test "games of other teams, and unreadable games, are skipped" do
      games = [
        final(110, 100, %{"home_team" => %{"id" => 2}}),
        final(110, 100, %{"datetime" => "bad"}),
        final(110, 100, %{"datetime" => nil}),
        final(110, 100, %{"status_state" => "canceled"}),
        "not a game"
      ]

      assert %{record: nil, live: nil, last_game: nil, next_game: nil} = Nba.facts(20, games)
    end

    test "the TTL depends on the state of the game" do
      ny = Nba.facts(20, knicks_games())
      lal = Nba.facts(14, lakers_games())

      # In progress: 30 s, which the free tier's 5 requests a minute allows.
      assert Nba.ttl(lal, ~U[2026-10-31 03:00:00Z]) == 30_000

      # Final (the last game ended within 12 hours): hours, but not past the
      # next game (3 days away here: the 6 hour cap applies).
      assert Nba.ttl(ny, ~U[2026-10-31 02:00:00Z]) == :timer.hours(6)

      # Final, and the next game starts in 3 hours: until 2 minutes before it.
      soon = %{ny | next_game: %{ny.next_game | date: ~U[2026-10-31 05:00:00Z]}}
      assert Nba.ttl(soon, ~U[2026-10-31 02:00:00Z]) == :timer.minutes(178)
      # ... and never below a minute.
      assert Nba.ttl(soon, ~U[2026-10-31 04:59:00Z]) == 60_000

      # Scheduled (the last game ended long ago): up to an hour, or until
      # shortly before the start, whichever is first.
      assert Nba.ttl(ny, ~U[2026-11-02 23:00:00Z]) == :timer.hours(1)
      assert Nba.ttl(ny, ~U[2026-11-03 00:00:00Z]) == :timer.minutes(28)
    end

    test "with no next game the card is cached for up to an hour, or six after a final" do
      facts = %{live: nil, last_game: %{date: ~U[2027-06-01 00:00:00Z]}, next_game: nil}

      assert Nba.ttl(facts, ~U[2027-06-01 03:00:00Z]) == :timer.hours(6)
      assert Nba.ttl(facts, ~U[2027-07-01 03:00:00Z]) == :timer.hours(1)
      assert Nba.ttl(%{facts | last_game: nil}, ~U[2027-07-01 03:00:00Z]) == :timer.hours(1)
    end

    test "season/1 is the year the season starts, from July on" do
      assert Nba.season(~U[2026-11-06 12:00:00Z]) == 2026
      assert Nba.season(~U[2027-06-15 12:00:00Z]) == 2026
      assert Nba.season(~U[2027-07-01 00:00:00Z]) == 2027
    end

    test "parse_teams/1 keys today's teams by lowercase name, with the Clippers alias" do
      teams = Nba.parse_teams(nba_fixture("teams"))

      assert map_size(teams) == 30
      assert teams["new york knicks"] == %{id: 20, name: "New York Knicks"}
      assert teams["la clippers"] == %{id: 13, name: "LA Clippers"}
      # The former Denver Nuggets (no conference) do not replace today's.
      assert teams["denver nuggets"].id == 8
    end
  end

  describe "fetch/1" do
    setup do
      stub_nba()
      :ok
    end

    test "returns the card and a TTL, with the key and a descriptive User-Agent" do
      assert {:ok, card, ttl} = Nba.fetch(team("New York Knicks"))

      assert card.type == "sports_team"
      assert card.title == "New York Knicks"
      assert card.facts.record == "2-4"
      assert is_integer(ttl) and ttl >= 60_000

      assert_received {:nba_request, "/teams", %{user_agent: user_agent, authorization: key}}
      assert user_agent =~ "Knowseek"
      assert key == "test-key"

      season = to_string(Nba.season(DateTime.utc_now()))

      assert_received {:nba_request, "/games/20",
                       %{
                         params: %{
                           "team_ids" => ["20"],
                           "seasons" => [^season],
                           "per_page" => "100"
                         }
                       }}
    end

    test "a card is one games request, and the team list is fetched once" do
      assert {:ok, _card, _ttl} = Nba.fetch(team("New York Knicks"))
      assert {:ok, _card, _ttl} = Nba.fetch(team("Los Angeles Lakers"))

      assert requests() == ["/teams", "/games/20", "/games/14"]
    end

    test "a game in progress is a 30 second card" do
      assert {:ok, %{facts: %{live: %{team_score: 80}}}, 30_000} =
               Nba.fetch(team("Los Angeles Lakers"))
    end

    test "a second page is fetched when there is one, and no more than two" do
      [first | rest] = knicks_games()

      stub_nba(
        games_nyk: fn conn ->
          case conn.query_params["cursor"] do
            nil -> Req.Test.json(conn, %{"data" => [first], "meta" => %{"next_cursor" => 7}})
            "7" -> Req.Test.json(conn, %{"data" => rest, "meta" => %{"next_cursor" => 8}})
          end
        end
      )

      assert {:ok, %{facts: %{record: "2-4"}}, _ttl} = Nba.fetch(team("New York Knicks"))
      assert requests() == ["/teams", "/games/20", "/games/20"]
    end

    test "Los Angeles Clippers is balldontlie's LA Clippers" do
      # No stub for team 13: the request shows which team was looked up.
      assert {:error, {:http_status, 404}} = Nba.fetch(team("Los Angeles Clippers"))
      assert "/games/13" in requests()
    end

    test "a label that matches no team is an error, not a guess" do
      assert Nba.fetch(team("Seattle SuperSonics")) ==
               {:error, {:no_nba_team, "Seattle SuperSonics"}}
    end

    test "an entity without a label is an error" do
      assert Nba.fetch(team("x", label: nil)) == {:error, :no_label}
    end

    test "a 429 is a rate limit with the Retry-After of balldontlie" do
      stub_nba(
        games_nyk: fn conn ->
          conn |> Plug.Conn.put_resp_header("retry-after", "30") |> Plug.Conn.send_resp(429, "")
        end
      )

      assert Nba.fetch(team("New York Knicks")) == {:error, {:rate_limited, 30_000}}
    end

    test "a 401 (a wrong key) is an error" do
      stub_nba(games_nyk: &Plug.Conn.send_resp(&1, 401, "Unauthorized"))
      assert Nba.fetch(team("New York Knicks")) == {:error, :unauthorized}
    end

    test "a games answer without a list of games is an error" do
      stub_nba(games_nyk: %{"error" => "nope"})
      assert Nba.fetch(team("New York Knicks")) == {:error, :unexpected_body}
    end

    test "a failing team list is an error" do
      Req.Test.stub(Balldontlie, &Plug.Conn.send_resp(&1, 503, ""))

      assert Nba.fetch(team("New York Knicks")) == {:error, {:http_status, 503}}
    end

    test "an empty, malformed or short team list is an error, and is not cached as a success" do
      teams = nba_fixture("teams")["data"]

      for {body, expected} <- [
            {%{}, {:too_few_teams, 0}},
            {%{"data" => "none"}, {:too_few_teams, 0}},
            {%{"data" => [%{"id" => 1}]}, {:too_few_teams, 0}},
            {%{"data" => Enum.take(teams, 24)}, {:too_few_teams, 24}}
          ] do
        # A failed answer that is read starts a refetch in the background
        # (the backoff is 0). Let it finish before the stub changes, or it
        # would answer for the next body.
        :ok = Knowseek.Cache.await(Knowseek.Cards.NbaTeams, :nba)
        stub_nba(teams: body)
        assert Nba.fetch(team("New York Knicks")) == {:error, expected}
      end

      # The list comes back: the next request fetches it again (the test
      # config has no backoff) and the card works.
      :ok = Knowseek.Cache.await(Knowseek.Cards.NbaTeams, :nba)
      stub_nba()
      assert {:ok, %{title: "New York Knicks"}, _ttl} = Nba.fetch(team("New York Knicks"))
    end
  end
end
