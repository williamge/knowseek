defmodule Knowseek.Cards.Providers.Nba do
  @moduledoc """
  `Knowseek.Cards.Provider` for NBA teams, from the balldontlie API
  (`Knowseek.Cards.Balldontlie`, free tier). ADR 0028; task 031 before it.

  ## Which entities

  An entity gets a card when an API key is configured, it is a sports team
  (`Knowseek.Entities.kind/1`) and Wikidata says it plays in the NBA now
  (`leagues` holds Q155223, from P118). The league is what keeps the
  Westchester Knicks (NBA G League) and the former Denver Nuggets of the
  National Basketball League (their NBA claim has an end date) from getting
  the Knicks' or the Nuggets' card, which a match by label alone would do.
  The label is then matched to `full_name` in balldontlie's `/teams` list
  (`Los Angeles Clippers` is its `LA Clippers`). A label that matches no team
  is an error, not a guess. Without a key no entity is handled, so the query
  has no card.

  ## The card

  `type: "sports_team"`, `title` (balldontlie's team name) and `facts`:

    * `source`, `league` - `"balldontlie"`, `"NBA"`.
    * `record` - wins and losses in the regular season's final games, for
      example `"2-4"`, or `nil` before the first one. The NBA Cup final does
      not count (the league leaves it out of the standings); play-in and
      playoff games are not regular season.
    * `live` - the game in progress, or `nil`: `opponent`, `home_away`
      (`"home"`/`"away"`), `team_score`, `opponent_score`, `period`, `clock`
      and `status_text` (the status and the clock, such as `"3rd Qtr 4:32"`
      or `"Halftime"`).
    * `last_game` - the last final game, or `nil`: `date`, `opponent`,
      `home_away`, `result` (`"W"`/`"L"`), `team_score`, `opponent_score`.
    * `next_game` - the next scheduled game, or `nil`: `date`, `opponent`,
      `home_away`.

  Everything comes from one `/games` call for the team's season (100 games a
  page; a second page only late in the playoffs). The free tier has no
  injuries and no standings.

  ## TTL by state

  `ttl/2`: a game in progress is `30 s`. The free tier allows 5 requests a
  minute per key, so two live cards refreshed every 30 s leave room for the
  others; a 429 stops the fetches for its `Retry-After` and the cards go
  stale. A game that tipped off in the last 12 hours (about 9.5 hours after
  it ended) is final: nothing changes until the next game, so up to 6 hours.
  Otherwise a game is scheduled: up to an hour, to catch a postponement. In
  both of the last two cases the card is never cached past two minutes
  before the next game's start, and never for less than a minute.
  """
  @behaviour Knowseek.Cards.Provider

  alias Knowseek.Cache
  alias Knowseek.Cards.Balldontlie
  alias Knowseek.Entities
  alias Knowseek.Entities.Entity

  # Wikidata: National Basketball Association.
  @nba "Q155223"
  # Wikidata labels that differ from balldontlie's `full_name`.
  @aliases %{"los angeles clippers" => "la clippers"}

  @teams_cache Knowseek.Cards.NbaTeams
  @teams_key :nba
  # The NBA has 30 teams. A teams answer with fewer than this (an empty or
  # malformed 200) is an error: it must not be cached as a success for a day.
  @min_teams 25
  # balldontlie's `/teams` also lists former teams, with no conference.
  @conferences ["East", "West"]
  @default_teams_backoff :timer.seconds(30)

  # A season has at most about 110 games (82, the Cup's knockout games, the
  # play-in, four playoff rounds): two pages of 100.
  @per_page 100
  @max_pages 2

  @live_ttl :timer.seconds(30)
  @min_ttl :timer.seconds(60)
  @scheduled_cap :timer.hours(1)
  @final_cap :timer.hours(6)
  # How long after tip-off (not after the final) a card counts as final.
  @final_window_seconds 12 * 3600
  @lead_ms :timer.minutes(2)

  @impl true
  def handles?(%Entity{} = entity) do
    Entities.kind(entity) == :sports_team and @nba in entity.leagues and
      Balldontlie.configured?()
  end

  @impl true
  def fetch(%Entity{} = entity) do
    now = DateTime.utc_now()

    with {:ok, %{id: team_id, name: name}} <- team(entity),
         {:ok, games} <- fetch_games(team_id, season(now)) do
      facts = facts(team_id, games)
      {:ok, %{type: "sports_team", title: name, facts: facts}, ttl(facts, now)}
    end
  end

  @doc """
  The balldontlie season (the year it starts) that is current or next at
  `date`: from July, the season that starts in the autumn.
  """
  @spec season(DateTime.t()) :: integer()
  def season(%DateTime{year: year, month: month}) when month >= 7, do: year
  def season(%DateTime{year: year}), do: year - 1

  ## Upstream

  defp team(%Entity{label: label}) when is_binary(label) do
    with {:ok, teams} <- teams() do
      case Map.fetch(teams, team_key(label)) do
        {:ok, team} -> {:ok, team}
        :error -> {:error, {:no_nba_team, label}}
      end
    end
  end

  defp team(_entity), do: {:error, :no_label}

  # The teams list changes once a decade, so it has its own long-lived cache.
  # This runs in a card fetch task, so waiting for the first fetch is fine.
  defp teams(retry? \\ true) do
    case Cache.get(@teams_cache, @teams_key, &fetch_teams/0,
           ttl: :timer.hours(24),
           backoff: teams_backoff(),
           timeout: :timer.seconds(10)
         ) do
      {status, teams, _as_of} when status in [:fresh, :stale] ->
        {:ok, teams}

      {:unavailable, :cache_not_running} ->
        {:error, :cache_not_running}

      # Nothing cached, or a failure: past its backoff the `get` above started a
      # fetch, so wait for it. Inside the backoff the wait returns at once.
      :pending when retry? ->
        await_teams()

      {:unavailable, _reason} when retry? ->
        await_teams()

      :pending ->
        {:error, :teams_unavailable}

      {:unavailable, reason} ->
        {:error, reason}
    end
  end

  defp await_teams do
    :ok = Cache.await(@teams_cache, @teams_key, :timer.seconds(15))
    teams(false)
  end

  # Config `teams_backoff` (milliseconds) is for tests: with 0 the next
  # request refetches a failed team list at once.
  defp teams_backoff do
    :knowseek
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:teams_backoff, @default_teams_backoff)
  end

  defp fetch_teams do
    with {:ok, body} <- Balldontlie.get("teams") do
      case parse_teams(body) do
        teams when map_size(teams) >= @min_teams -> {:ok, teams}
        teams -> {:error, {:too_few_teams, map_size(teams)}}
      end
    end
  end

  # The team's games of `season`, following `next_cursor` for at most
  # @max_pages pages. A page that fails fails the card.
  defp fetch_games(team_id, season, cursor \\ nil, page \\ 1, acc \\ []) do
    params = [{"team_ids[]", team_id}, {"seasons[]", season}, {"per_page", @per_page}]
    params = if cursor, do: params ++ [{"cursor", cursor}], else: params

    case Balldontlie.get("games", params) do
      {:ok, %{"data" => games} = body} when is_list(games) ->
        case next_cursor(body) do
          next when next != nil and page < @max_pages ->
            fetch_games(team_id, season, next, page + 1, acc ++ games)

          _last_page ->
            {:ok, acc ++ games}
        end

      {:ok, _body} ->
        {:error, :unexpected_body}

      {:error, _reason} = error ->
        error
    end
  end

  defp next_cursor(%{"meta" => %{"next_cursor" => next}}), do: next
  defp next_cursor(_body), do: nil

  ## Parsing (pure)

  @doc """
  The current NBA teams of a balldontlie `/teams` body, keyed by lowercase
  `full_name` (with the aliases applied): `%{id: integer, name: full_name}`.
  """
  @spec parse_teams(map()) :: %{String.t() => %{id: integer(), name: String.t()}}
  def parse_teams(body) do
    for %{"data" => teams} when is_list(teams) <- [body],
        %{"id" => id, "full_name" => name, "conference" => conference} <- teams,
        is_integer(id) and is_binary(name) and conference in @conferences,
        into: %{} do
      {team_key(name), %{id: id, name: name}}
    end
  end

  defp team_key(name) do
    key = name |> String.split() |> Enum.join(" ") |> String.downcase()
    Map.get(@aliases, key, key)
  end

  @doc """
  The card facts from the balldontlie games (`data` of `/games`) of the team
  with id `team_id`. See the module doc for the shape.
  """
  @spec facts(integer(), [map()]) :: map()
  def facts(team_id, games) do
    games =
      games
      |> Enum.flat_map(&game(&1, team_id))
      |> Enum.sort_by(& &1.date, DateTime)

    finals = Enum.filter(games, &(&1.state == :final))

    %{
      source: "balldontlie",
      league: "NBA",
      record: record(finals),
      live: games |> Enum.find(&(&1.state == :live)) |> live(),
      last_game: finals |> List.last() |> finished(),
      next_game: games |> Enum.find(&(&1.state == :scheduled)) |> upcoming()
    }
  end

  defp game(game, team_id) when is_map(game) do
    home = game["home_team"] || %{}
    visitor = game["visitor_team"] || %{}

    {mine, theirs, home_away, team_score, opponent_score} =
      cond do
        home["id"] == team_id ->
          {home, visitor, "home", game["home_team_score"], game["visitor_team_score"]}

        visitor["id"] == team_id ->
          {visitor, home, "away", game["visitor_team_score"], game["home_team_score"]}

        true ->
          {nil, nil, nil, nil, nil}
      end

    with %{} <- mine,
         state when state != :skip <- state(game),
         {:ok, date} <- start(game) do
      [
        %{
          state: state,
          date: date,
          opponent: theirs["full_name"],
          home_away: home_away,
          team_score: score(team_score),
          opponent_score: score(opponent_score),
          period: game["period"],
          clock: clock(game["time"]),
          status: game["status"],
          counts: game["postseason"] == false and game["ist_stage"] != "Championship"
        }
      ]
    else
      _not_a_game_of_this_team -> []
    end
  end

  defp game(_game, _team_id), do: []

  # `status_state` is the documented lifecycle. A postponed, cancelled,
  # suspended or abandoned game is neither played nor coming, so it is left
  # out. Without `status_state`, `status` is "Final", a quarter, or the start
  # time of a game that has not begun (`period` 0).
  defp state(%{"status_state" => state}) when is_binary(state) do
    case state do
      "in_progress" -> :live
      "final" -> :final
      state when state in ["scheduled", "delayed"] -> :scheduled
      _other -> :skip
    end
  end

  defp state(%{"postponed" => true}), do: :skip
  defp state(%{"status" => "Final"}), do: :final
  defp state(%{"period" => period}) when is_integer(period) and period > 0, do: :live
  defp state(%{"status" => status}) when is_binary(status), do: :scheduled
  defp state(_game), do: :skip

  defp start(%{"datetime" => datetime}) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, date, _offset} -> {:ok, DateTime.truncate(date, :second)}
      {:error, _reason} -> :error
    end
  end

  defp start(_game), do: :error

  defp record([]), do: nil

  defp record(finals) do
    counted = Enum.filter(finals, &(&1.counts and result(&1) != nil))

    if counted == [] do
      nil
    else
      wins = Enum.count(counted, &(result(&1) == "W"))
      "#{wins}-#{length(counted) - wins}"
    end
  end

  defp result(%{team_score: mine, opponent_score: theirs})
       when is_integer(mine) and is_integer(theirs) and mine != theirs,
       do: if(mine > theirs, do: "W", else: "L")

  defp result(_game), do: nil

  defp live(nil), do: nil

  defp live(game) do
    game
    |> Map.take([:opponent, :home_away, :team_score, :opponent_score, :period, :clock])
    |> Map.put(:status_text, status_text(game))
  end

  # "3rd Qtr" and "4:32" make "3rd Qtr 4:32"; "Halftime" has no clock.
  defp status_text(%{status: status, clock: clock}) when is_binary(status) do
    status = String.trim(status)

    cond do
      status == "" -> clock
      clock == nil or String.contains?(status, clock) -> status
      true -> "#{status} #{clock}"
    end
  end

  defp status_text(%{clock: clock}), do: clock

  defp finished(nil), do: nil

  defp finished(game) do
    game
    |> Map.take([:date, :opponent, :home_away, :team_score, :opponent_score])
    |> Map.put(:result, result(game))
  end

  defp upcoming(nil), do: nil
  defp upcoming(game), do: Map.take(game, [:date, :opponent, :home_away])

  defp clock(time) when is_binary(time) do
    case String.trim(time) do
      "" -> nil
      "Final" -> nil
      time -> time
    end
  end

  defp clock(_time), do: nil

  defp score(value) when is_integer(value), do: value
  defp score(_none), do: nil

  ## TTL

  @doc """
  How long a card with these `facts` stays fresh at `now`, in milliseconds.
  See "TTL by state" in the module doc.
  """
  @spec ttl(map(), DateTime.t()) :: pos_integer()
  def ttl(%{live: %{}}, _now), do: @live_ttl

  def ttl(%{last_game: last} = facts, now) do
    cap = if final?(last, now), do: @final_cap, else: @scheduled_cap
    until_next = until_start(facts.next_game, now)

    until_next |> min(cap) |> max(@min_ttl)
  end

  defp final?(%{date: date}, now), do: DateTime.diff(now, date) < @final_window_seconds
  defp final?(nil, _now), do: false

  defp until_start(%{date: date}, now), do: DateTime.diff(date, now, :millisecond) - @lead_ms
  defp until_start(nil, _now), do: @final_cap
end
