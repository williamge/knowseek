# Working with agents in parallel

For whoever plans and starts the work (a person, or an agent that starts
subagents). `AGENTS.md` is for the agent that does one task. Read it first.
The prompt templates are in [`agent-brief.md`](agent-brief.md).

This is the process that ran four tasks at once (014, 011, 020, 012) and merged
four PRs. It also lists what went wrong and what stopped it from happening
again.

## The loop

1. **Pick tasks that do not collide.** Compare the `Area` line of each task
   (`docs/tasks/`). Tasks that edit the same module, the same table, or the
   same API response are serial. Typical collisions:
   - Two tasks in `Knowseek.Discovery` (015, 003, 004, 007, 016, 006).
   - Two tasks that add migrations on one table, or that both change `Documents.ingest/1` (011, 017).
   - A task that documents a response shape (013) next to one that changes it (014, 006).
   - `POST /api/search` and the search controller (014, 006).
2. **Reserve numbers before you start.** Agents that each pick "the next free
   number" collide. Give each agent its ADR number and, if it may add
   follow-up tasks, its task file numbers. Tell the others which numbers are taken.
   Migrations are different: the generator picks the version (see below).
3. **Start one subagent per task** with the templates in `agent-brief.md`: one
   shared contract and one self-contained task prompt each. Do not set the
   workflow in your head; put it in the prompt (see "What the agents got right and wrong").
4. **Review before merge.** For every PR that changes code, start a read-only
   reviewer agent (template in `agent-brief.md`) before a human reads it. Skip it for
   docs-only PRs. Send the findings back to the author agent. It still has the context.
5. **Merge one PR at a time, in an order that minimizes conflicts** (PRs that only add files first). After each merge:
   - `git fetch origin`, then rebase the next branch on `origin/main` (resolve
     the docs conflicts by keeping both sides in number order).
   - Run `make check-quiet` again before you push, and wait for CI. CI does not run again by itself when `main` moves.
   - Read the result of the test run as new evidence. A rebase can break a test that was green alone (see below).
6. **Clean up.** `make worktree-rm NAME=...` and delete the local branch for
   every merged task. Remove container images that an agent built.

## Rules that stopped collisions

- **One worktree per task, absolute paths.** Agents edit only inside
  `../knowseek-worktrees/<name>`. Tell them to use absolute paths for every file
  read and edit. One agent wrote to the main checkout through a relative path
  (it reverted the change); another started on `main` before the worktree workflow existed.
- **Migrations come from the generator only.** Run `cd backend && mix
  ecto.gen.migration name`. Never type a version by hand. Two agents that ran the generator in the same
  second got the same version, and both PRs were green alone. `make
  check-migrations` (part of `make check`) now fails on a duplicate, a bad
  name, or a future version. After a rebase, run `make check-quiet`. If it reports a
  duplicate, delete the newer file and generate it again.
- **Never share state that other agents rely on.** Docker: never `docker
  compose down -v`, never touch the shared Postgres volume or another
  worktree's database; stop only your own container. Only one `app` container
  runs per compose project (ADR 0014).
- **Agents never merge and never push to `main`.** A human merges (ADR 0010).
- **Single test files run through `make test ARGS=...`**, so the worktree's own databases are used.

## What the agents got right and wrong

Observed on the first wave (four tasks, one subagent each, no model override;
about 5 to 7 minutes each). All four PRs went green on CI on the first push.
The independent review still found these. CI did not see any of them:

| Finding | Where |
| --- | --- |
| Two PRs added a migration with the same version. | 011, 020 |
| A very long query made `POST /api/topics` return 500 (btree index row limit). | 020 |
| A test that claimed to be concurrent ran on one connection and would pass without the fix. | 020 |
| Tests that pass with the new code deleted (candidate factor, `hnsw.ef_search`, create-database). | 014, 012 |
| Design hazards: an alias URL with a changed body rewrote the aliased document; a mirror overwrote source and title. | 011 |
| A claim in the docs that was not true: separate worktrees do not get separate `app` containers in one compose project. | 012 |
| An agent edited the main checkout through relative tool paths; the owner's dev server broke. CI cannot see it. | see below |

A test was also broken only after the rebase: 014's test used five documents
with the same body, and 011's exact-duplicate aliasing merged them into one.
It is a reminder that "green alone" does not mean "green together".

One incident was not in a PR: an agent used relative paths in read/edit, and
the edits landed in the main checkout, where the owner's dev server was
watching. The dev server broke. Cause: the tools resolve relative paths against
the main checkout, not against a `cd` in bash. CI cannot catch it, because the
PR itself was fine. Mitigation: absolute paths in every brief, plus the
tripwire `scripts/assert-main-clean` (run by `make check`, `make check-quiet`,
and `make guard-main`). The tripwire detects the mistake; it does not prevent it.

Practical consequences:

- Write the `Acceptance` section of each task prompt as behavior to prove, and
  ask for a smoke run of the real path. The agents did it, and it caught real issues (for example the HNSW row cap in 014).
- Ask reviewers to say whether CI would have caught each finding. It shows how much to trust a green run.
- Tests an agent writes for its own code verify that code. Ask the reviewer
  to check that each new test fails when the code it covers is removed.

## Models and cost (observed, not a rule)

Subagents ran on the same model as the planner (`claude-sonnet-5-5`) because no
`model` was set. A review took about 1.5 to 2 minutes and cost about $0.27 to $0.35. Implementation tasks took 5 to 7
minutes; their cost was not recorded. There is no evidence yet that a different model or effort level is needed:
the review findings above were gaps in tests and in knowledge of other branches, not in single-file logic. If you change the model, compare the reviewer's findings by category before and after.

## When to leave tasks serial

Do not parallelize when a task changes the shape of something others document
or consume (the search response, the `Source` behaviour, the router for auth,
`Documents.ingest/1`), when two tasks add migrations to the same table, or when
a task needs a decision from the owner first (for example 003 needs a search provider).
