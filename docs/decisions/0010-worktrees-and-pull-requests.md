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
- At the time of writing the repository was private on GitHub's free plan,
  which does not allow branch protection or rulesets, so "CI must pass" and
  "nothing goes to `main` directly" were conventions in `AGENTS.md`. See the
  second Update below: GitHub now enforces them.
- Each worktree costs its own `_build`, `deps`, and `node_modules`, and two
  Postgres databases. `make worktree-rm` reclaims the databases and files.
- Servers in several worktrees need different ports: `make dev PORT=4010`.

## Update (2026-10-31)

The risk that an agent edits `main` directly still exists: the read/edit/write
tools resolve relative paths against the main checkout, not against a `cd` in
bash. `scripts/assert-main-clean` (run by `make check`, `make check-quiet`, and
`make guard-main`) detects it: from a worktree, it fails when the main checkout
has uncommitted changes. It does not prevent the edit. When the owner has
deliberate local edits in main, set `ALLOW_DIRTY_MAIN=1` to skip it. Run from
the main checkout itself, it does nothing.

## Update (2026-10-31): repository is public, ruleset enforces the rules

The repository is public (AGPL-3.0-only) and the ruleset "main protection" is
active on `main`: a pull request is required (0 approvals), the `backend`,
`frontend`, and `image` checks are required, `main` cannot be deleted or
force-pushed, there are no bypass actors, and merged branches are deleted. The
rule that a human merges is unchanged: agents never merge and never push to
`main`; GitHub now rejects direct pushes as well.

## Update (2026-10-31): seven required checks

The ruleset "main protection" now requires seven checks, not three: `backend`,
`frontend`, `image`, `migrations`, `docs`, `shellcheck`, and `secrets`. The
`security` job (`mix hex.audit`, `mix deps.audit`, `mix sobelow`, `npm audit`)
runs on every pull request but is not required, by design: an advisory
published today must not block pull requests that did not touch the
dependencies. Where this ADR or `AGENTS.md` says "the three checks", read
the seven. See `docs/decisions/0020-ci-hardening.md`.
