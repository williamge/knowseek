# 0028. NBA card: balldontlie's free tier, a key per operator

- Status: Accepted
- Date: 2026-11-06

Supersedes the sports-team source in [0017](0017-live-fact-cards.md) (decision 3). Issue [#65](https://github.com/williamge/knowseek/issues/65); background in [storage and licenses](../notes/storage-and-licenses.md).

## Context

The NBA team card read ESPN's undocumented site API. Disney's terms, linked from espn.com, forbid exactly that: "access, monitor, copy or extract the Disney Products using a robot, spider, script, or other automated means", and grant "personal, noncommercial use only". Keeping the data in memory does not help: the access itself breaks the terms.

The card needs a source that is free, allows a script, and has live scores and the schedule. Terms were read on the vendors' own pages on 2026-11-06; two keyless hosts were probed with our User-Agent.

## Evidence

| Source | Free, key | Terms on scripted access and caching | Rate limit | Free-tier data | Verdict |
| --- | --- | --- | --- | --- | --- |
| **balldontlie** | $0 tier; free account and key | [Terms](https://www.balldontlie.io/terms): "You may use Data for any lawful personal or commercial purpose … copying, caching, storing, archiving, modifying, combining, analyzing, publishing, displaying". "No attribution … is required". Bans automated access only "except through our official interfaces"; the API is one. Keys "may not be shared". | 5 requests a minute ([docs](https://docs.balldontlie.io/)) | Teams, games (score, quarter, clock, `status_state`). Injuries, standings and box scores are paid tiers. | **Chosen** |
| NBA.com (`cdn.nba.com`, `data.nba.com`, `stats.nba.com`) | Undocumented, no key | [Terms](https://www.nba.com/termsofuse): "for your personal, noncommercial use"; you may not "display … for public … purposes … without the written permission"; statistics only for "private, non-commercial purposes" with "prominent attribution to NBA.com". | None published | Everything | Rejected. HTTP 403 to our User-Agent on `cdn.nba.com` and `data.nba.com`; `data.nba.net` and `stats.nba.com` did not answer. Showing the data to others is forbidden. |
| TheSportsDB | Shared key `123`, no account | [Terms](https://www.thesportsdb.com/docs_terms_of_use.php): "You can scrape, copy and modify content returned from the API"; free use is "for your development projects". | 30 a minute | [Docs](https://www.thesportsdb.com/docs_api_guide): last and next events give one result, "free key only shows home event"; tables 5 rows; live scores are premium ($9 a month). | Rejected: the free tier cannot fill the card. |
| API-Sports (API-NBA) | 100 a day, 10 a minute; account | Terms page behind a Cloudflare challenge. Search snippet: "forbidden to have multiple accounts to increase the limit of the free plan"; data "prohibited to resell". | 100 a day | The free plan restricts seasons: a current-season query answered `errors.plan` (API-Football, same company, [third-party check of 2026-10-16](https://raw.githubusercontent.com/withqwerty/football-docs/main/docs/api-football/api-access.md)). | Rejected: 100 a day cannot follow a live game. |
| Wikidata | No key | CC0 | — | Arena, head coach, founding date. No scores. | Static only. |
| Wikipedia team-season article | No key | CC BY-SA; the API is already used | — | A volunteer game log: no live score, no tip-off time, wikitext that differs per team. | Fallback only, not built. |
| Basketball-Reference | No API | [Terms](https://www.sports-reference.com/termsofuse.html): no automated access "in a manner that adversely impacts site performance"; no use for "prompting, or instructing artificial intelligence". | 20 a minute, or blocked for up to a day | Not live | Rejected. |
| MySportsFeeds | Paid ($5 a month minimum) | — | — | — | Rejected. |

## Decision

**The NBA team card reads balldontlie's free tier. Each operator signs up for a free key and sets `BALLDONTLIE_API_KEY`. Without a key there is no NBA card.**

- Client `Knowseek.Cards.Balldontlie` (`https://api.balldontlie.io/v1`, the key in `Authorization`, a descriptive User-Agent, 4 s timeout, no retries). 401 is `:unauthorized`; 429 stops the NBA cards cache for its `Retry-After`.
- Provider `Knowseek.Cards.Providers.Nba`. The Wikidata league check of 0017 is unchanged; `handles?/1` is also false without a key, so the query gets `none`, not an error. The label is matched to `full_name` in `/teams` (East and West only: the list also has former teams), cached for a day; `Los Angeles Clippers` is `LA Clippers`.
- One request per card: `/games?team_ids[]=<id>&seasons[]=<year>&per_page=100`, with a second page if `next_cursor` says so (only late in the playoffs).
- The facts keep their shape, without `injuries`. `source` is `"balldontlie"`. The record is counted from the regular season's final games; the NBA Cup final does not count, as in the league's standings. `status_text` is the status and the clock (`"3rd Qtr 4:32"`, `"Halftime"`). A postponed, cancelled, suspended or abandoned game is left out.
- A live card lasts 30 s, not 15: the free key allows 5 requests a minute. The other TTLs are unchanged.

## Consequences

- The card loses injuries (a paid tier) and refreshes a live game every 30 s instead of 15.
- Every operator needs a free account; the checklist's "no account" box fails, its "no key, or a free key" box passes. An instance without a key simply has no NBA card.
- With more than about two live games watched at once, a key runs out of requests: the 429 stops the NBA fetches for `Retry-After`, and those cards show as `stale` with their time.
- We count the record. A game missing from balldontlie, or corrected later, skews it.
- The test fixtures are written by hand from the documented shape (an API call needs a key). The first real answer should be compared with them.
- balldontlie can change its terms (last updated 2026-10-20) or its free tier. The client is the only place that knows the API.
