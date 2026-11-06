# balldontlie fixtures

Answers of the balldontlie NBA API (`https://api.balldontlie.io/v1/...`) for the tests of `Knowseek.Cards.Providers.Nba`. They are **written by hand** from the response shape in the [documentation](https://docs.balldontlie.io/) (2026-11-06), not recorded: an API call needs a key, and a key needs an account. The games are made up but plausible (2026-27 season, balldontlie season `2026`). Each game has the documented top-level fields except the per-quarter scores, timeouts and bonus flags, which the provider does not read.

| File | Request | Contents |
| --- | --- | --- |
| `teams.json` | `/teams` | The 30 teams with balldontlie's ids (the Knicks are 20, the Lakers 14, the Clippers 13 as `LA Clippers`), plus two former teams with a blank `conference` (the Chicago Stags and the 1949-50 Denver Nuggets, whose name matches today's Nuggets). |
| `games_nyk.json` | `/games?team_ids[]=20&seasons[]=2026&per_page=100` | The Knicks (2-4): six final games, the last on 2026-10-30 at Philadelphia (L 93-98); a postponed game; two scheduled games, the next on 2026-11-03 against Brooklyn. |
| `games_lal_live.json` | `/games?team_ids[]=14&seasons[]=2026&per_page=100` | The Lakers (1-1): two final games, one in progress (`status_state: "in_progress"`, `3rd Qtr`, `4:32` left, at Golden State, 80-85) and the next scheduled game. |

Neither answer has `meta.next_cursor`: one page holds the season. Tests that need a second page build it inline.

When a key is available, record one real `/games` answer and compare its shape with these files.

## License

balldontlie's terms allow storing and redistributing the data ("copying, caching, storing, archiving, modifying … distributing"). These files hold made-up game data in its shape and are test fixtures only.
