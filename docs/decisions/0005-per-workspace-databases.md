# 0005. One database per Conductor workspace

- Status: Accepted
- Date: 2026-10-30

## Context

Many agents work in parallel, each in its own Conductor workspace (a git
worktree). If they shared a database, migrations on one branch and test runs
on another would collide.

## Decision

Run one shared Postgres container (compose project `knowseek`). In
`config/dev.exs` and `config/test.exs`, add a suffix derived from
`CONDUCTOR_WORKSPACE_NAME` to the database name. Outside Conductor the names
are plain `knowseek_dev` and `knowseek_test`. The Conductor archive script
drops the workspace's databases.

## Consequences

- Workspaces are isolated, and `run_mode = "concurrent"` is safe.
- Each workspace starts with an empty dev database. Use `priv/repo/seeds.exs`
  for shared sample data.
- Renaming a workspace changes its database name. Run `make setup` again.
