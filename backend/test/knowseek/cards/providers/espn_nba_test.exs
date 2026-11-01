defmodule Knowseek.Cards.Providers.EspnNbaTest do
  # The ESPN stub runs in tasks of the provider, so Req.Test is shared.
  use ExUnit.Case, async: false

  import Knowseek.Fixtures
  import Req.Test, only: [set_req_test_from_context: 1]

  alias Knowseek.Cards.Providers.EspnNba
  alias Knowseek.Entities.{Entity, Wikidata}

  setup :set_req_test_from_context

  setup do
    # The team list is cached for a day in the application's cache: start
    # every test with it empty, so that each one sees its own requests.
    reset_espn_teams_cache()
  end

  # The Lakers' schedule lists the game in progress without scores; the
  # summary request is answered by `summary`.
  defp stub_noscore_schedule(summary) do
    schedule = espn_fixture("schedule_lal_live_noscore")
    teams = espn_fixture("teams")
    roster = espn_fixture("roster_lal")

    Req.Test.stub(Knowseek.Cards.Espn, fn conn ->
      path = conn.request_path

      cond do
        String.ends_with?(path, "/teams") -> Req.Test.json(conn, teams)
        String.ends_with?(path, "/schedule") -> Req.Test.json(conn, schedule)
        String.ends_with?(path, "/roster") -> Req.Test.json(conn, roster)
        true -> summary.(conn)
      end
    end)
  end

  defp team(label, attrs \\ []) do
    struct!(
      %Entity{id: "Q-" <> label, label: label, types: ["Q13393265"], leagues: ["Q155223"]},
      attrs
    )
  end

  defp requests(acc \\ []) do
    receive do
      {:espn_request, path, _user_agent} -> requests([path | acc])
    after
      20 -> Enum.reverse(acc)
    end
  end

  describe "handles?/1" do
    test "an NBA team" do
      assert EspnNba.handles?(team("New York Knicks"))
    end

    test "the Westchester Knicks play in the G League, not the NBA" do
      stub_wikidata()
      assert {:ok, candidates} = Wikidata.search("knicks", [])

      westchester = Enum.find(candidates, &(&1.label == "Westchester Knicks"))
      knicks = Enum.find(candidates, &(&1.label == "New York Knicks"))

      assert westchester.leagues == ["Q842793"]
      refute EspnNba.handles?(westchester)
      assert EspnNba.handles?(knicks)
    end

    test "a team with no current NBA league is not handled (a defunct team of the same name)" do
      refute EspnNba.handles?(team("Denver Nuggets", leagues: []))
      refute EspnNba.handles?(team("Denver Nuggets", leagues: ["Q1429493"]))
    end

    test "an NBA league alone is not enough: the entity must be a sports team" do
      refute EspnNba.handles?(team("Some Game", types: ["Q18431960"]))
    end

    test "a company is not handled" do
      stub_wikidata()
      assert {:ok, [nvidia | _]} = Wikidata.search("nvidia", [])
      refute EspnNba.handles?(nvidia)
    end
  end

  describe "facts/3 and ttl/2" do
    test "a team between games: record, last game, next game, injuries" do
      facts = EspnNba.facts("18", espn_fixture("schedule_ny"), espn_fixture("roster_ny"))

      assert facts.source == "ESPN"
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

      assert facts.next_game == %{
               date: ~U[2026-11-03 00:30:00Z],
               opponent: "Brooklyn Nets",
               home_away: "home"
             }

      assert facts.injuries == [%{player: "Jose Alvarado", status: "Out"}]
    end

    test "a game in progress: score, period and clock, and the one before it" do
      facts =
        EspnNba.facts("13", espn_fixture("schedule_lal_live"), espn_fixture("roster_lal"))

      assert facts.record == "4-1"

      assert facts.live == %{
               opponent: "Golden State Warriors",
               home_away: "away",
               team_score: 80,
               opponent_score: 85,
               period: 3,
               clock: "0.0",
               status_text: "End of 3rd"
             }

      assert facts.last_game.date == ~U[2026-10-29 02:30:00Z]
      assert facts.last_game.result in ["W", "L"]
      assert facts.next_game.date == ~U[2026-11-02 02:00:00Z]

      assert facts.injuries == [
               %{player: "Adou Thiero", status: "Out"},
               %{player: "Ziaire Williams", status: "Out"}
             ]
    end

    test "no games and no injuries is a card with empty fields" do
      facts = EspnNba.facts("18", %{"team" => %{}, "events" => []}, %{"athletes" => []})

      assert %{record: nil, live: nil, last_game: nil, next_game: nil, injuries: []} = facts
    end

    test "events that are not games of this team, and unreadable events, are skipped" do
      schedule = %{
        "events" => [
          %{"date" => "bad", "competitions" => []},
          %{"id" => "1", "date" => "2026-11-03T00:30Z", "competitions" => [%{}]}
        ]
      }

      assert %{live: nil, last_game: nil, next_game: nil} =
               EspnNba.facts("18", schedule, %{"athletes" => []})
    end

    test "the TTL depends on the state of the game" do
      ny = EspnNba.facts("18", espn_fixture("schedule_ny"), espn_fixture("roster_ny"))
      lal = EspnNba.facts("13", espn_fixture("schedule_lal_live"), espn_fixture("roster_lal"))

      # In progress: 15 s, ESPN's cache is a few seconds.
      assert EspnNba.ttl(lal, ~U[2026-10-31 03:00:00Z]) == 15_000

      # Final (the last game ended within 12 hours): hours, but not past the
      # next game (3 days away here: the 6 hour cap applies).
      assert EspnNba.ttl(ny, ~U[2026-10-31 02:00:00Z]) == :timer.hours(6)

      # Final, and the next game starts in 3 hours: until 2 minutes before it.
      soon = %{ny | next_game: %{ny.next_game | date: ~U[2026-10-31 05:00:00Z]}}
      assert EspnNba.ttl(soon, ~U[2026-10-31 02:00:00Z]) == :timer.minutes(178)
      # ... and never below a minute.
      assert EspnNba.ttl(soon, ~U[2026-10-31 04:59:00Z]) == 60_000

      # Scheduled (the last game ended long ago): up to an hour, or until
      # shortly before the start, whichever is first.
      assert EspnNba.ttl(ny, ~U[2026-11-02 23:00:00Z]) == :timer.hours(1)
      assert EspnNba.ttl(ny, ~U[2026-11-03 00:00:00Z]) == :timer.minutes(28)
    end

    test "with no next game the card is cached for up to an hour, or six after a final" do
      facts = %{live: nil, last_game: %{date: ~U[2027-06-01 00:00:00Z]}, next_game: nil}

      assert EspnNba.ttl(facts, ~U[2027-06-01 03:00:00Z]) == :timer.hours(6)
      assert EspnNba.ttl(facts, ~U[2027-07-01 03:00:00Z]) == :timer.hours(1)
      assert EspnNba.ttl(%{facts | last_game: nil}, ~U[2027-07-01 03:00:00Z]) == :timer.hours(1)
    end

    test "parse_teams/1 keys teams by lowercase name, with the Clippers alias" do
      teams = EspnNba.parse_teams(espn_fixture("teams"))

      assert map_size(teams) == 30
      assert teams["new york knicks"] == "18"
      assert teams["la clippers"] == "12"
    end
  end

  describe "fetch/1" do
    setup do
      stub_espn()
      :ok
    end

    test "returns the card and a TTL, with a descriptive User-Agent" do
      assert {:ok, card, ttl} = EspnNba.fetch(team("New York Knicks"))

      assert card.type == "sports_team"
      assert card.title == "New York Knicks"
      assert card.facts.record == "2-4"
      assert is_integer(ttl) and ttl >= 60_000

      assert_received {:espn_request, "/basketball/nba/teams", [user_agent]}
      assert user_agent =~ "Knowseek"
    end

    test "a card needs a schedule and a roster request, and the team list is fetched once" do
      assert {:ok, _card, _ttl} = EspnNba.fetch(team("New York Knicks"))
      assert {:ok, _card, _ttl} = EspnNba.fetch(team("Los Angeles Lakers"))

      assert Enum.sort(requests()) ==
               Enum.sort([
                 "/basketball/nba/teams",
                 "/basketball/nba/teams/18/schedule",
                 "/basketball/nba/teams/18/roster",
                 "/basketball/nba/teams/13/schedule",
                 "/basketball/nba/teams/13/roster"
               ])
    end

    test "a game in progress is a 15 second card" do
      assert {:ok, %{facts: %{live: %{team_score: 80}}}, 15_000} =
               EspnNba.fetch(team("Los Angeles Lakers"))
    end

    test "a schedule with the scores needs no summary request" do
      assert {:ok, _card, _ttl} = EspnNba.fetch(team("Los Angeles Lakers"))
      refute "/basketball/nba/summary" in requests()
    end

    test "a game in progress listed without scores gets them from the summary" do
      stub_espn(schedule_lal_live: espn_fixture("schedule_lal_live_noscore"))

      assert {:ok, %{facts: %{live: live}}, 15_000} = EspnNba.fetch(team("Los Angeles Lakers"))

      assert live == %{
               opponent: "Golden State Warriors",
               home_away: "away",
               team_score: 84,
               opponent_score: 98,
               period: 4,
               clock: "7:12",
               status_text: "7:12 - 4th"
             }

      assert "/basketball/nba/summary" in requests()
    end

    test "a summary that fails leaves the live game without a score" do
      stub_noscore_schedule(&Plug.Conn.send_resp(&1, 500, ""))

      assert {:ok, %{facts: %{live: live}}, 15_000} = EspnNba.fetch(team("Los Angeles Lakers"))
      assert %{team_score: nil, opponent_score: nil, status_text: "7:12 - 4th"} = live
    end

    test "a rate-limited summary fails the card" do
      stub_noscore_schedule(fn conn ->
        conn |> Plug.Conn.put_resp_header("retry-after", "9") |> Plug.Conn.send_resp(429, "")
      end)

      assert EspnNba.fetch(team("Los Angeles Lakers")) == {:error, {:rate_limited, 9_000}}
    end

    test "Los Angeles Clippers is ESPN's LA Clippers" do
      # No stub for team 12: the request shows which team was looked up.
      assert {:error, {:http_status, 404}} = EspnNba.fetch(team("Los Angeles Clippers"))
      assert "/basketball/nba/teams/12/schedule" in requests()
    end

    test "a label that matches no ESPN team is an error, not a guess" do
      assert EspnNba.fetch(team("Seattle SuperSonics")) ==
               {:error, {:no_espn_team, "Seattle SuperSonics"}}
    end

    test "an entity without a label is an error" do
      assert EspnNba.fetch(team("x", label: nil)) == {:error, :no_label}
    end

    test "a 429 is a rate limit with the Retry-After of ESPN" do
      Req.Test.stub(Knowseek.Cards.Espn, fn conn ->
        if String.ends_with?(conn.request_path, "/teams") do
          Req.Test.json(conn, espn_fixture("teams"))
        else
          conn |> Plug.Conn.put_resp_header("retry-after", "30") |> Plug.Conn.send_resp(429, "")
        end
      end)

      assert EspnNba.fetch(team("New York Knicks")) == {:error, {:rate_limited, 30_000}}
    end

    test "a failing roster fails the card: no injuries is not the same as unknown" do
      Req.Test.stub(Knowseek.Cards.Espn, fn conn ->
        cond do
          String.ends_with?(conn.request_path, "/teams") ->
            Req.Test.json(conn, espn_fixture("teams"))

          String.ends_with?(conn.request_path, "/schedule") ->
            Req.Test.json(conn, espn_fixture("schedule_ny"))

          true ->
            Plug.Conn.send_resp(conn, 500, "")
        end
      end)

      assert EspnNba.fetch(team("New York Knicks")) == {:error, {:http_status, 500}}
    end

    test "a failing team list is an error" do
      Req.Test.stub(Knowseek.Cards.Espn, &Plug.Conn.send_resp(&1, 503, ""))

      assert EspnNba.fetch(team("New York Knicks")) == {:error, {:http_status, 503}}
    end

    test "an empty, malformed or short team list is an error, and is not cached as a success" do
      teams = espn_fixture("teams")
      [%{"leagues" => [league]} = sport] = teams["sports"]
      short_league = %{league | "teams" => Enum.take(league["teams"], 24)}
      short = %{teams | "sports" => [%{sport | "leagues" => [short_league]}]}

      for {body, expected} <- [
            {%{}, {:too_few_teams, 0}},
            {%{"sports" => "none"}, {:too_few_teams, 0}},
            {%{"sports" => [%{"leagues" => [%{"teams" => [%{"team" => %{}}]}]}]},
             {:too_few_teams, 0}},
            {short, {:too_few_teams, 24}}
          ] do
        # A failed answer that is read starts a refetch in the background
        # (the backoff is 0). Let it finish before the stub changes, or it
        # would answer for the next body.
        :ok = Knowseek.Cache.await(Knowseek.Cards.EspnTeams, :nba)
        Req.Test.stub(Knowseek.Cards.Espn, &Req.Test.json(&1, body))
        assert EspnNba.fetch(team("New York Knicks")) == {:error, expected}
      end

      # The list comes back: the next request fetches it again (the test
      # config has no backoff) and the card works.
      :ok = Knowseek.Cache.await(Knowseek.Cards.EspnTeams, :nba)
      stub_espn()
      assert {:ok, %{title: "New York Knicks"}, _ttl} = EspnNba.fetch(team("New York Knicks"))
    end
  end
end
