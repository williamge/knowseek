# 026. Remove the follow-topic feature

- Status: done
- Area: `Knowseek.Topics`, Oban config, migrations, web, docs
- Depends on: none

## Goal

Remove "follow topic" entirely. It was never explicitly asked for. The one
convincing use case, ongoing news, needs news and feed sources that do not
exist yet. Following will be rethought once they exist (task 027). Clean
cutover: no shims, flags, or dead code. See ADR 0015.

## Scope

- Backend: `Knowseek.Topics` and its workers, `TopicController`/`TopicJSON`,
  the `/api/topics` routes, the Oban cron entry (and the Cron plugin), the
  topic tests and fixtures.
- A migration that drops `topics` and deletes the queued Oban jobs of the
  removed workers. Make migration `20261031002441` self-contained.
- Frontend: follow button, topics page and route, home chips, nav link,
  `useTopics`, API calls, types, styles, tests.
- Docs: README, AGENTS.md, ARCHITECTURE, ADR 0015 (0012 superseded), tasks 019,
  020, 024, 004, 005, 009, 018; add task 027.
- Keep `max_age_seconds` on search (task 005).

## Acceptance criteria

- `grep -ri topic` in `backend/lib`, `backend/test`, `backend/config`,
  `frontend/src`, `frontend/test`, `README.md`, `AGENTS.md`, and
  `docs/ARCHITECTURE.md` finds nothing about the removed feature.
- A fresh `mix ecto.setup` works. Migrating a database that has a topic row and
  queued topic jobs drops the table and deletes the jobs.
- `GET` and `POST /api/topics` return 404. Search works and the page has no
  follow button.
- `make check-quiet` passes.

## Outcome

Built: see the scope list and ADR 0015 for the decisions (the `default` queue
is gone, `max_age_seconds` on search stays, migration `20261031002441` now
deletes rows instead of calling the removed `Deduplicate` module).

Left out:

- Existing topic rows are not exported or preserved.
- Historical text in ADRs, task files, and the old migrations still says
  "topic" on purpose.

Follow-ups: task 027 (design session about following), task 004 (reconsider
its scope).
