# ESPN fixtures

Recorded responses of ESPN's public site API (`https://site.api.espn.com/apis/site/v2/sports/basketball/nba/...`), captured on 2026-10-31 (2026-27 regular season) for the tests of `Knowseek.Cards.Providers.EspnNba`. The content is public score and schedule data (team names, records, game dates, scores, injury statuses). Every file is trimmed to the fields the provider parses, in ESPN's own shape; links, logos, venues, broadcasts, tickets, player biographies and the like were dropped.

| File | Request | Contents |
| --- | --- | --- |
| `teams.json` | `/teams` | The 30 NBA teams: `id`, `slug`, `abbreviation`, `displayName` (note `LA Clippers`). |
| `schedule_ny.json` | `/teams/18/schedule` | The Knicks (2-4): two completed games (Oct 29 at Chicago, Oct 30 at Philadelphia) and the next two scheduled games (Brooklyn, Chicago). All `status.type.state` values are `post` or `pre`. |
| `roster_ny.json` | `/teams/18/roster` | The Knicks' players: `displayName` and, for Jose Alvarado, `injuries` (`Out`). |
| `schedule_lal_live_noscore.json` | `/teams/13/schedule` | The Lakers again, recorded about 10 minutes later in the same game (7:12 left in the 4th): ESPN now listed the game in progress (`state: "in"`) with no `score` on its competitors, as it does at times. The fetch then asks `/summary` for that game. |
| `summary_lal_live.json` | `/summary?event=401909285` | Trimmed to `header.competitions[0]`: the `status` and the competitors' `id`, `homeAway`, `score` (Golden State 98, Lakers 84, 7:12 left in the 4th). The real answer is about 380 KB. |
| `schedule_lal_live.json` | `/teams/13/schedule` | The Lakers (4-1): two completed games, one in progress (`state: "in"`, end of the 3rd quarter at Golden State, 80-85, recorded while it was played) and the next scheduled game. |
| `roster_lal.json` | `/teams/13/roster` | The Lakers' players, two of them with `injuries` (`Out`). |

The trimmed `schedule_*` files keep the events around the current game, not the whole season, and only `team.id`, `team.displayName` and `team.recordSummary` of the team object.

ESPN sends `cache-control: max-age=1` on `/schedule` and `/roster`, which is why the card TTL is never below 15 s.

## License

ESPN's API is not officially documented or licensed for reuse. The files hold factual game data only and are kept as test fixtures; the application calls the API at run time and does not redistribute it.
