defmodule Knowseek.Cards.Providers.EspnNba do
  @moduledoc """
  `Knowseek.Cards.Provider` for NBA teams, from ESPN's public site API
  (`Knowseek.Cards.Espn`). Task 031.

  ## Which entities

  An entity gets a card when it is a sports team (`Knowseek.Entities.kind/1`)
  and Wikidata says it plays in the NBA now (`leagues` holds Q155223, from
  P118). The league is what keeps the Westchester Knicks (NBA G League) and
  the former Denver Nuggets of the National Basketball League (their NBA
  claim has an end date) from getting the Knicks' or the Nuggets' card, which
  a match by label alone would do. The label is then matched to ESPN's
  `displayName` in the NBA `/teams` list (`Los Angeles Clippers` is ESPN's
  `LA Clippers`). A label that matches no team is an error, not a guess.

  ## The card

  `type: "sports_team"`, `title` (ESPN's team name) and `facts`:

    * `source`, `league` - `"ESPN"`, `"NBA"`.
    * `record` - overall record, for example `"2-4"`, or `nil`.
    * `live` - the game in progress, or `nil`: `opponent`, `home_away`
      (`"home"`/`"away"`), `team_score`, `opponent_score`, `period`, `clock`
      and `status_text` (ESPN's short detail, such as `"End of 3rd"`).
    * `last_game` - the last completed game, or `nil`: `date`, `opponent`,
      `home_away`, `result` (`"W"`/`"L"`), `team_score`, `opponent_score`.
    * `next_game` - the next scheduled game, or `nil`: `date`, `opponent`,
      `home_away`.
    * `injuries` - `player` and `status` (`"Out"`, `"Day-To-Day"`, ...) of
      every player the roster lists with an injury.

  The record, the games and the live score come from one `/schedule` call
  (`team.recordSummary` is fresher than `/teams/<id>`, which is cached for
  minutes), the injuries from `/roster`. No news and no odds.

  ## TTL by state

  `ttl/2`: a game in progress is `15 s` (ESPN's own cache is a few seconds). A
  game that tipped off in the last 12 hours (about 9.5 hours after it
  ended) is final: nothing changes until the next game, so up to 6 hours.
  Otherwise a game is scheduled: up to an hour,
  to catch a postponement or an injury report. In both of the last two
  cases the card is never cached past two minutes before the next game's
  start, and never for less than a minute.
  """
  @behaviour Knowseek.Cards.Provider

  alias Knowseek.Cache
  alias Knowseek.Cards.Espn
  alias Knowseek.Entities
  alias Knowseek.Entities.Entity

  @path "basketball/nba"
  # Wikidata: National Basketball Association.
  @nba "Q155223"
  # Wikidata labels that differ from ESPN's `displayName`.
  @aliases %{"los angeles clippers" => "la clippers"}

  @teams_cache Knowseek.Cards.EspnTeams
  @teams_key :nba
  # The NBA has 30 teams. A teams answer with fewer than this (an empty or
  # malformed 200) is an error: it must not be cached as a success for a day.
  @min_teams 25
  @default_teams_backoff :timer.seconds(30)

  @live_ttl :timer.seconds(15)
  @min_ttl :timer.seconds(60)
  @scheduled_cap :timer.hours(1)
  @final_cap :timer.hours(6)
  # How long after tip-off (not after the final) a card counts as final.
  @final_window_seconds 12 * 3600
  @lead_ms :timer.minutes(2)

  @impl true
  def handles?(%Entity{} = entity) do
    Entities.kind(entity) == :sports_team and @nba in entity.leagues
  end

  @impl true
  def fetch(%Entity{} = entity) do
    with {:ok, team_id} <- team_id(entity),
         {:ok, schedule, roster} <- fetch_team(team_id),
         {:ok, schedule} <- add_live_scores(schedule, team_id) do
      facts = facts(team_id, schedule, roster)
      title = get_in(schedule, ["team", "displayName"]) || entity.label

      {:ok, %{type: "sports_team", title: title, facts: facts}, ttl(facts, DateTime.utc_now())}
    end
  end

  ## Upstream

  defp team_id(%Entity{label: label}) when is_binary(label) do
    with {:ok, teams} <- teams() do
      case Map.fetch(teams, team_key(label)) do
        {:ok, id} -> {:ok, id}
        :error -> {:error, {:no_espn_team, label}}
      end
    end
  end

  defp team_id(_entity), do: {:error, :no_label}

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
    with {:ok, body} <- Espn.get("#{@path}/teams") do
      case parse_teams(body) do
        teams when map_size(teams) >= @min_teams -> {:ok, teams}
        teams -> {:error, {:too_few_teams, map_size(teams)}}
      end
    end
  end

  # One request each, in parallel. Both must succeed: an empty injury list
  # for a roster that failed to load would be wrong, not unknown.
  defp fetch_team(team_id) do
    schedule = Task.async(fn -> Espn.get("#{@path}/teams/#{team_id}/schedule") end)
    roster = Task.async(fn -> Espn.get("#{@path}/teams/#{team_id}/roster") end)

    case {Task.await(schedule, :infinity), Task.await(roster, :infinity)} do
      {{:ok, schedule}, {:ok, roster}} -> {:ok, schedule, roster}
      {{:error, reason}, _roster} -> {:error, reason}
      {_schedule, {:error, reason}} -> {:error, reason}
    end
  end

  # ESPN's `/schedule` sometimes lists a game in progress without scores. Its
  # `/summary` for that one game has them (a big answer: only asked for when
  # needed). A summary that fails leaves the card without a score; a rate
  # limit fails the card, like any other call.
  defp add_live_scores(schedule, team_id) do
    case live_event_without_score(schedule, team_id) do
      nil ->
        {:ok, schedule}

      event_id ->
        case Espn.get("#{@path}/summary", event: event_id) do
          {:ok, summary} -> {:ok, merge_summary(schedule, event_id, summary)}
          {:error, {:rate_limited, _ms}} = error -> error
          {:error, _reason} -> {:ok, schedule}
        end
    end
  end

  defp live_event_without_score(schedule, team_id) do
    Enum.find_value(schedule["events"] || [], fn event ->
      competition = List.first(event["competitions"] || []) || %{}
      mine = Enum.find(competition["competitors"] || [], &(get_in(&1, ["team", "id"]) == team_id))

      if get_in(competition, ["status", "type", "state"]) == "in" and mine != nil and
           score(mine["score"]) == nil,
         do: event["id"]
    end)
  end

  @doc """
  Puts the scores and the status of the summary of game `event_id` into that
  game of `schedule`, so that the score and the clock belong together.
  """
  @spec merge_summary(map(), String.t(), map()) :: map()
  def merge_summary(schedule, event_id, summary) do
    competition =
      get_in(summary, ["header", "competitions"]) |> List.wrap() |> List.first() || %{}

    scores = Map.new(competition["competitors"] || [], &{&1["id"], &1["score"]})

    update_event = fn event ->
      [own | rest] = event["competitions"]

      competitors = Enum.map(own["competitors"] || [], &put_score(&1, scores))
      own = %{own | "competitors" => competitors}
      own = if competition["status"], do: Map.put(own, "status", competition["status"]), else: own
      %{event | "competitions" => [own | rest]}
    end

    Map.update!(schedule, "events", fn events ->
      Enum.map(events, fn
        %{"id" => ^event_id} = event -> update_event.(event)
        event -> event
      end)
    end)
  end

  defp put_score(competitor, scores) do
    case Map.fetch(scores, get_in(competitor, ["team", "id"])) do
      {:ok, score} when is_binary(score) -> Map.put(competitor, "score", score)
      _no_score -> competitor
    end
  end

  ## Parsing (pure)

  @doc false
  @spec parse_teams(map()) :: %{String.t() => String.t()}
  def parse_teams(body) do
    for %{"sports" => sports} when is_list(sports) <- [body],
        %{"leagues" => leagues} when is_list(leagues) <- sports,
        %{"teams" => teams} when is_list(teams) <- leagues,
        %{"team" => %{"id" => id, "displayName" => name}} when is_binary(name) <- teams,
        into: %{} do
      {team_key(name), id}
    end
  end

  defp team_key(name) do
    key = name |> String.split() |> Enum.join(" ") |> String.downcase()
    Map.get(@aliases, key, key)
  end

  @doc """
  The card facts from an ESPN `/schedule` and `/roster` body of the team with
  id `team_id`. See the module doc for the shape.
  """
  @spec facts(String.t(), map(), map()) :: map()
  def facts(team_id, schedule, roster) do
    games =
      (schedule["events"] || [])
      |> Enum.flat_map(&game(&1, team_id))
      |> Enum.sort_by(& &1.date, DateTime)

    %{
      source: "ESPN",
      league: "NBA",
      record: get_in(schedule, ["team", "recordSummary"]),
      live: games |> Enum.find(&(&1.state == "in")) |> live(),
      last_game: games |> Enum.filter(&(&1.state == "post" and &1.completed)) |> List.last(),
      next_game: games |> Enum.find(&(&1.state == "pre")),
      injuries: injuries(roster)
    }
    |> Map.update!(:last_game, &finished/1)
    |> Map.update!(:next_game, &upcoming/1)
  end

  defp game(event, team_id) do
    with competition when is_map(competition) <- List.first(event["competitions"] || []),
         %{"state" => state} = type <- get_in(competition, ["status", "type"]),
         {:ok, date} <- parse_date(event["date"]),
         competitors = competition["competitors"] || [],
         %{} = mine <- Enum.find(competitors, &(get_in(&1, ["team", "id"]) == team_id)),
         %{} = theirs <- Enum.find(competitors, &(&1 != mine)) do
      [
        %{
          state: state,
          completed: type["completed"] == true,
          date: date,
          opponent: get_in(theirs, ["team", "displayName"]),
          home_away: mine["homeAway"],
          team_score: score(mine["score"]),
          opponent_score: score(theirs["score"]),
          winner: mine["winner"],
          period: get_in(competition, ["status", "period"]),
          clock: get_in(competition, ["status", "displayClock"]),
          status_text: type["shortDetail"]
        }
      ]
    else
      _not_a_game_of_this_team -> []
    end
  end

  defp live(nil), do: nil

  defp live(game) do
    Map.take(game, [
      :opponent,
      :home_away,
      :team_score,
      :opponent_score,
      :period,
      :clock,
      :status_text
    ])
  end

  defp finished(nil), do: nil

  defp finished(game) do
    result =
      cond do
        game.winner == true -> "W"
        game.winner == false -> "L"
        true -> nil
      end

    game
    |> Map.take([:date, :opponent, :home_away, :team_score, :opponent_score])
    |> Map.put(:result, result)
  end

  defp upcoming(nil), do: nil
  defp upcoming(game), do: Map.take(game, [:date, :opponent, :home_away])

  # ESPN dates have no seconds: `2026-11-03T00:30Z`.
  defp parse_date(date) when is_binary(date) do
    date = if date =~ ~r/T\d\d:\d\dZ\z/, do: String.replace_suffix(date, "Z", ":00Z"), else: date

    case DateTime.from_iso8601(date) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_date), do: :error

  defp score(%{"displayValue" => value}) when is_binary(value), do: score(value)
  defp score(%{"value" => value}) when is_number(value), do: trunc(value)
  defp score(value) when is_number(value), do: trunc(value)

  defp score(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _no_score -> nil
    end
  end

  defp score(_none), do: nil

  # `athletes` is a flat list for the NBA; other sports group them.
  defp injuries(roster) do
    athletes =
      Enum.flat_map(roster["athletes"] || [], fn
        %{"items" => items} when is_list(items) -> items
        athlete -> [athlete]
      end)

    for %{"injuries" => [%{"status" => status} | _]} = athlete <- athletes,
        is_binary(status),
        name = athlete["displayName"] || athlete["fullName"],
        is_binary(name) do
      %{player: name, status: status}
    end
  end

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
