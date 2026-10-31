# 036. Prepare the repository for going public

- Status: done
- Area: repo root, docs, docker-compose.yml, test fixtures
- Depends on: none

## Goal

Make the repository safe and legal to publish: a license, a security policy, a secret scan, a dependency license audit, attribution for third-party fixtures, and a Postgres port that is not exposed to the network. No behaviour changes.

## Scope

- `LICENSE` (AGPL-3.0), SPDX metadata, README license section, ADR 0019.
- Dependency license audit; secret scan of the full history; personal-data grep.
- `SECURITY.md`, README "Status and security".
- Postgres published on `127.0.0.1` only.
- Fixture attribution and `NOTICE`.

## Acceptance criteria

- `LICENSE` is the unmodified official AGPL-3.0 text.
- No real secret in history; the scan passes with a minimal allowlist.
- `make check-quiet` passes.

## Outcome

Built:

- `LICENSE` (official text, 34523 bytes, sha256 `0d96a4ff68ad6d4b6f1f30f713b18d5184912ba8dd389f86aa7710db079abcb0`), `AGPL-3.0-only` in `backend/mix.exs` (`package: [licenses: ...]`, compiles with `--warnings-as-errors`) and `frontend/package.json`, README license and "Status and security" sections, `NOTICE`, `SECURITY.md`, ADR 0019 with the dependency audit (35 Elixir deps: 19 Apache-2.0, 16 MIT; npm production deps: all MIT; nothing flagged).
- gitleaks over all history (54 commits): 4 findings, all `generic-api-key` on the Phoenix dev/test `secret_key_base` (`backend/config/dev.exs`, `test.exs`, two commits each). Triage: dev/test-only, expected. `.gitleaks.toml` allows that rule on those two paths only; the rescan finds 0.
- `git grep` for `williamgelhar|@gmail` in the working tree: no matches.
- `docker-compose.yml`: Postgres on `127.0.0.1:${PGPORT:-5432}`. Host clients (Makefile, `dev.exs`/`test.exs` with `PGHOST` default `localhost`) are unchanged; CI uses a GitHub services container, not compose.
- Fixture READMEs for Wikipedia (CC BY-SA 4.0) and Wikidata (CC0).

Left out:

- No CI job for the secret scan or license audit (separate CI hardening task).
- Development-only npm dependencies and base images were not audited.
- "Private repository" wording is not changed yet (the owner updates it after branch protection is on): `AGENTS.md` line 104 (CI paragraph: "private repository ... branch protection needs a paid plan") and `docs/decisions/0010-worktrees-and-pull-requests.md` Consequences (line 34, "The repository is private on GitHub's free plan ..."). README, `backend/AGENTS.md`, `docs/ARCHITECTURE.md`, and `docs/agent-brief.md` have none.

Follow-ups:

- Update the two places above after the flip and enable branch protection.
- CI hardening: secret scan and license check.
- Decide on a CLA/DCO before taking outside pull requests (ADR 0019).
