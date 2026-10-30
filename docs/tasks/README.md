# Task backlog

One file per task. Each task is sized for one agent on one branch.

## Workflow

1. Pick an `open` task whose dependencies are `done`. Read `AGENTS.md` first.
2. Set `Status: in progress (<branch name>)` in your branch.
3. When you finish, set `Status: done` and add an `## Outcome` section.
4. Add new task files for follow-up work. Use the next free number.

## Index

Status lives only in each task file, so parallel branches do not conflict on this table.

| # | Task | Depends on |
| --- | --- | --- |
| [001](001-real-embedding-adapter.md) | Real embedding adapter | none |
| [002](002-wikipedia-source.md) | Wikipedia discovery source | none |
| [003](003-web-search-source.md) | Web search discovery source | none |
| [004](004-feed-source.md) | RSS/Atom feed source for topics | none |
| [005](005-freshness-aware-coverage.md) | Freshness-aware coverage | none |
| [006](006-discovery-status-for-callers.md) | Tell callers when discovery finishes | none |
| [007](007-query-planning.md) | LLM query planning for sources | 002 or 003 |
| [008](008-answer-synthesis.md) | Answer synthesis with citations | 001 |
| [009](009-users-and-api-keys.md) | Users and API keys | none |
| [010](010-observability.md) | Telemetry and job dashboard | none |
| [011](011-url-canonicalization-and-dedup.md) | URL canonicalization and duplicate detection | none |
| [012](012-release-and-container.md) | Release build and app container | none |
| [013](013-openapi-spec.md) | OpenAPI spec for the API | none |
| [014](014-one-hit-per-document.md) | One search hit per document | none |
| [015](015-retry-failed-discovery-sources.md) | Retry failed discovery sources | none |
| [016](016-limit-discovery-abuse.md) | Limit discovery abuse | 009 |
| [017](017-re-embed-job.md) | Re-embed chunks after a model change | 001 |
| [018](018-serve-frontend-in-production.md) | Serve the web UI in production | 012 |
| [019](019-web-ui-follow-ups.md) | Web UI follow-ups | 006, 008, 013 |

Tasks with no shared dependency can run in parallel. Tasks 002, 003, and 004
all add sources. They touch different files, but read each other's merged
code first if one lands before you start.
