# Task backlog

One file per task. Each task is sized for one agent on one branch.

## Workflow

1. Pick an `open` task whose dependencies are `done`. Read `AGENTS.md` first.
2. Create a worktree with `make worktree NAME=<short-task-name>`. Work only there.
3. Set `Status: in progress (<branch name>)` in your branch.
4. When you finish, set `Status: done` and add an `## Outcome` section.
5. Add new task files for follow-up work. Use the next free number.
6. Open a pull request, wait for green CI, and report the URL. Do not merge.

## Index

Status lives only in each task file, so parallel branches do not conflict on this table.

| # | Task | Depends on |
| --- | --- | --- |
| [001](001-real-embedding-adapter.md) | Real embedding adapter | none |
| [002](002-wikipedia-source.md) | Wikipedia discovery source | none |
| [003](003-web-search-source.md) | Web search discovery source | none |
| [004](004-feed-source.md) | RSS/Atom feed source | none |
| [005](005-freshness-aware-coverage.md) | Freshness-aware coverage | none |
| [006](006-discovery-status-for-callers.md) | Tell callers when discovery finishes | none |
| [007](007-query-planning.md) | LLM query planning for sources | 002 or 003 |
| [008](008-answer-synthesis.md) | Answer synthesis with citations | 001 |
| [009](009-users-and-api-keys.md) | Users and API keys (parked) | none |
| [010](010-observability.md) | Telemetry and job dashboard (parked) | none |
| [011](011-url-canonicalization-and-dedup.md) | URL canonicalization and duplicate detection | none |
| [012](012-release-and-container.md) | Release build and app container | none |
| [013](013-openapi-spec.md) | OpenAPI spec for the API (parked) | none |
| [014](014-one-hit-per-document.md) | One search hit per document | none |
| [015](015-retry-failed-discovery-sources.md) | Retry failed discovery sources | none |
| [016](016-limit-discovery-abuse.md) | Limit discovery abuse (parked) | 009 |
| [017](017-re-embed-job.md) | Re-embed chunks after a model change | 001 |
| [018](018-serve-frontend-in-production.md) | Serve the web UI in production (parked) | 012 |
| [019](019-web-ui-follow-ups.md) | Web UI follow-ups | 006, 008, 013 |
| [020](020-unique-topics.md) | Topics unique by query (feature removed by 026) | none |
| [021](021-reliable-discovery-completion-in-ui.md) | Reliable discovery completion in the web UI (merged into 006) | 006 |
| [022](022-backfill-urls-and-near-duplicates.md) | Merge stored duplicate URLs; near-duplicate detection (parked) | 011 |
| [023](023-group-search-hits-in-sql.md) | Group search hits by document in SQL (parked) | 014 |
| [024](024-edit-topics.md) | Edit and pause topics (won't do, see 026) | 020 |
| [025](025-container-ci-smoke-and-publish.md) | Boot the container in CI and publish the image (parked) | 012 |
| [026](026-remove-topics.md) | Remove the follow-topic feature | none |
| [027](027-rethink-topics.md) | Rethink following, in a session with the owner (folded into 028) | none |
| [028](028-live-facts-for-entities.md) | Live facts for entities (design session) | none |
| [029](029-ollama-by-default.md) | Ollama by default, one command to start | none |
| [030](030-entity-resolution.md) | Entity resolution via Wikidata | none |
| [031](031-card-framework-sports.md) | Card framework and sports-team card (cache-only endpoint, background refresher) | 030 |
| [032](032-company-card.md) | Company card | 031 |
| [033](033-weather-card.md) | Weather card | 031 |
| [034](034-weather-location-context.md) | Location context for bare "weather" | 033 |
| [035](035-ranking-prior.md) | Ranking prior from document importance (done, [ADR 0018](../decisions/0018-ranking-prior.md)) | none |
| [036](036-public-repo-readiness.md) | Prepare the repository for going public | none |
| [037](037-ci-hardening.md) | CI hardening: migration roundtrip, docs consistency, security scans, secret scan, ShellCheck, Dependabot | none |
| [038](038-source-last-edited.md) | Show when the source says a page was last edited (done) | none |

Tasks with no shared dependency can run in parallel. Tasks 002, 003, and 004
all add sources. They touch different files, but read each other's merged
code first if one lands before you start.
