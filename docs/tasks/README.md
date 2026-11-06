# Task backlog

One file per task. Finished and parked tasks were removed from this directory;
their files are in the git history.

## Workflow

1. Pick an `open` task whose dependencies are done. Read `AGENTS.md` first.
2. Work on a branch. Set `Status: in progress (<branch name>)` in your branch.
3. When you finish, set `Status: done` and add an `## Outcome` section.
4. Add new task files for follow-up work. Use the next free number.
5. Open a pull request against `main` and wait for green CI. The owner merges.

## Index

Status lives only in each task file, so branches do not conflict on this table.

| # | Task | Depends on |
| --- | --- | --- |
| [003](003-web-search-source.md) | Web search discovery source | none |
| [004](004-feed-source.md) | RSS/Atom feed source | none |
| [006](006-discovery-status-for-callers.md) | Tell callers when discovery finishes | none |
| [007](007-query-planning.md) | LLM query planning for sources | none |
| [008](008-answer-synthesis.md) | Answer synthesis with citations | none |
| [015](015-retry-failed-discovery-sources.md) | Retry failed discovery sources | none |
| [017](017-re-embed-job.md) | Re-embed chunks after a model change | none |
| [019](019-web-ui-follow-ups.md) | Web UI follow-ups | 006, 008 |
| [021](021-reliable-discovery-completion-in-ui.md) | Reliable discovery completion in the web UI (merged into 006) | 006 |
| [024](024-edit-topics.md) | Edit and pause topics (won't do, see 026) | none |
| [027](027-rethink-topics.md) | Rethink following, in a session with the owner (folded into 028) | none |
| [034](034-weather-location-context.md) | Location context for bare "weather" | none |
| [041](041-card-by-entity-id.md) | Ask for the card of a chosen entity (a card by entity id, so that alternatives with one label are reachable) | none |
| [043](043-smarter-weather-queries.md) | Smarter weather queries (design session) | 034 |
| [048](048-local-first-shared-index.md) | Local-first instances that share what they find (design agenda, not decided) | none |

Tasks 003 and 004 both add sources. They touch different files, but read each
other's merged code first if one lands before you start.
