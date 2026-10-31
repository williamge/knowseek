# 0010. One worktree and one pull request per task

- Status: Accepted
- Date: 2026-10-30

Updates [0005](0005-per-workspace-databases.md): databases are named from
`KNOWSEEK_WORKSPACE`, with `CONDUCTOR_WORKSPACE_NAME` as the fallback.

## Context

Many agents work in parallel. Until now they shared one checkout unless a
human started a Conductor workspace, and nothing said how finished work reaches
`main`. An agent could edit `main` directly. One agent's half-done edits could
break another agent's test run.

## Decision

- Each task runs in its own git worktree, created by `make worktree NAME=...`
  at `../knowseek-worktrees/<name>`, on a branch of the same name that starts
  at `origin/main`.
- The worktree's `.env` sets `KNOWSEEK_WORKSPACE=<name>`. `config/dev.exs` and
  `config/test.exs` use it (or `CONDUCTOR_WORKSPACE_NAME`) as the database
  suffix, so each worktree has its own databases. `make worktree-rm` drops them.
- Finished work leaves as a pull request opened with `gh pr create`. Agents
  never commit to or push `main`, and never merge. A human reviews and merges.
- CI (`.github/workflows/ci.yml`) runs on every pull request. The `backend`
  and `frontend` jobs must pass before a merge.
- Single test files run through `make test ARGS=...`, so the Makefile loads
  `.env` and the worktree's databases are used.

## Consequences

- Parallel tasks cannot overwrite each other or `main`.
- The repository is private on GitHub's free plan, which does not allow
  branch protection or rulesets. "CI must pass" and "nothing goes to `main`
  directly" are conventions in `AGENTS.md`, not server-side rules. If the repo
  becomes public or moves to a paid plan, require the `backend` and `frontend`
  checks and a pull request on `main`, and this ADR can be superseded.
- Each worktree costs its own `_build`, `deps`, and `node_modules`, and two
  Postgres databases. `make worktree-rm` reclaims the databases and files.
- Servers in several worktrees need different ports: `make dev PORT=4010`.
