# Agent brief templates

Copy these when you start subagents (see `WORKING-WITH-AGENTS.md`). Replace
the `<placeholders>`. The contract goes in the shared context once; each task
prompt is self-contained, because the agents do not see this conversation.

## 1. Shared context (the contract)

```
# Goal
Repo: <absolute path of the main checkout> (Elixir/Phoenix backend + React/TypeScript frontend).
Implement one backlog task end to end and open a pull request.

# Contract
- Read first (relative to the main checkout): AGENTS.md (especially "How to work on a task" and "CI"), backend/AGENTS.md, docs/ARCHITECTURE.md, then your whole task file in docs/tasks/.
- WORKFLOW IS MANDATORY. From <main checkout> run `make worktree NAME=<your-name>`. Then do ALL work, including every file read/edit and every command, inside <worktrees dir>/<your-name>. Your read/edit/write/grep/glob tools resolve RELATIVE paths against the MAIN checkout, not against `cd` in bash, so EVERY file path MUST start with <worktrees dir>/<your-name>/. NEVER edit files in the main checkout. Run `git -C <main checkout> status --short` before your first edit and again before you open the PR; it must print nothing (if not, you caused it: move the change into the worktree, restore main with `git -C <main checkout> checkout -- <file>`, delete untracked files you created, tell the parent). `make guard-main` / `make check-quiet` check this too. NEVER commit to or push `main`. NEVER merge the PR.
- Run single backend test files with `make test ARGS=test/...` from your worktree root (never bare `mix test`). Run `make check-quiet` once at the end; it must pass.
- Migrations: only with `cd backend && mix ecto.gen.migration <name>`. Never write a version by hand.
- NEVER kill processes by name or pattern (no pkill, killall, or pgrep-then-kill by name): a pattern like `phx.server` kills the owner's dev server. Kill only PIDs you started and recorded, after checking their cwd is under your worktree (`lsof -p <pid> | grep cwd`). Use only your assigned CONDUCTOR_PORT pair; never ports 4000/4001.
- make check / check-quiet run `db-up`, which applies compose changes. If your task changes docker-compose.yml, running them recreates the SHARED Postgres container `knowseek-db-1` (same volume, brief downtime for the owner's API). Verify compose changes with `docker compose config`, tell the parent in your report, and never run `docker compose down`.
- Shared state: never run `docker compose down -v`; never touch the shared Postgres volume or other worktrees' databases; stop only containers you started; drop only databases you created.
- Repo rules: context boundaries, tests never hit the network, use fixtures in backend/test/support/fixtures.ex, `frontend/src/types.ts` mirrors `*JSON` views, update README.md / docs/ARCHITECTURE.md / AGENTS.md where your change makes them wrong.
- Other agents work in parallel on: <list of the other tasks>. Use only the numbers assigned to you: <ADR number>, <follow-up task file numbers or "none: list follow-ups in the Outcome only">. Add your row to docs/decisions/README.md and docs/tasks/README.md. Do not add other ADRs or task files.
- Before pushing: `git fetch origin && git rebase origin/main`, resolve conflicts (keep both sides' docs rows, in number order), rerun `make check-quiet` if anything non-trivial merged.
- Finish: commit, `git push -u origin <your-name>`, `gh pr create --base main` using .github/pull_request_template.md (fill every section honestly), then `gh pr checks --watch`. If CI fails, fix on the same branch and push again until green.
- Set your task file to `Status: done` with an `## Outcome` section (built, left out, follow-ups).
- Do not run `make worktree-rm`; leave the worktree in place.
- Final report: PR URL, CI result, what you verified by running it, what you left out, and the result of the main-checkout status check.
```

## 2. Task prompt (one per agent)

```
# Target
Task <NNN> (docs/tasks/<file>). Worktree name: `<your-name>`. ADR number: <NNNN>. <Follow-up task file number or "No follow-up task file number is assigned">.
Files likely: <modules, migration, controllers, frontend, docs>.

# Change
<The scope, as concrete decisions. Say what to do when the task file leaves a choice open, so the agent does not stop to ask.>

# Acceptance
<Behavior to prove: the tests that must exist, and the smoke run of the real path (a throwaway script, or `make dev PORT=<free port>` and curl) with what to report.
Finish with the PR open and CI green; report the PR URL, the CI result, and what you left out.>
```

Keep the "solution space" honest: say whether the design is fixed by the task
file or what is still open.

## 3. Reviewer prompt (read-only, one per PR)

```
# Goal
Independent review of one open pull request in <main checkout>. The PR was written by an AI agent that also wrote its own tests, so green CI is weak evidence. Find what its own tests would not catch.

# Contract
- READ-ONLY. Do not edit files, commit, push, create branches, or post comments/reviews on GitHub. Do not run `make worktree*`. Do not start servers or touch shared databases.
- Read first: AGENTS.md (architecture rules, testing rules), backend/AGENTS.md, docs/ARCHITECTURE.md, and the task file.
- Get the diff with `gh pr diff <N>`. The PR's code is in <worktree path>. Use `make test ARGS=...` only to reproduce a suspected bug with a throwaway test; delete it and report it.
- Review against: (1) the task file's Scope and Acceptance, line by line; (2) AGENTS.md architecture rules; (3) correctness: edge cases, races, error paths, data loss, migrations on existing data; (4) test quality: would each new test fail if the code it covers were removed?; (5) docs and ADR accuracy versus the code; (6) scope creep or silent scope shrink.
- Report: a table with severity (blocker / should-fix / nit), category, file:line, what is wrong and why, a concrete fix, and "would CI have caught it?". Then a verdict: merge as is / merge after fixes / needs rework. Report only findings you verified in code; mark the rest [INFERENCE].

# Target
PR #<N> (<title>), worktree `<name>`, task file <file>, ADR <file>. Pay special attention to: <the riskiest parts of this PR>.
```

## 4. Sending review findings back

Write to the original agent (it is idle and keeps its context): same branch,
same worktree, absolute paths, never merge. List each finding with the fix you
want, mark which ones to skip, and say which design choice is decided. End with:
rebase on `origin/main`, `make check-quiet`, push, `gh pr checks --watch`, and
report a table of finding, fixed or declined (with a reason), and the CI result.

## 5. Parent-side checks

- After EVERY subagent returns, run `git status --short` in the main checkout (what `scripts/assert-main-clean` does from a worktree) before you report success. It must print nothing.
- Restart the owner's dev servers after merges.
- After merges that change compose or Makefile start behaviour, check `docker ps` and restart the owner's `knowseek-start` service if needed.
