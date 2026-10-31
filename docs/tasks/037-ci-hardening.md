# 037. CI hardening

- Status: done
- Area: `.github/`, `scripts/`, `Makefile`, `backend/mix.exs`, docs
- Depends on: none

## Goal

CI proves more than "the tests pass": new migrations work on a database that holds data, the backlog and the docs agree with the files, dependencies and code have no known security problems, no secret is in the history, and the shell scripts are clean. Dependencies are kept current by Dependabot. Policy: `docs/decisions/0020-ci-hardening.md`.

## Scope

- Migration roundtrip (including irreversible migrations and a database with data).
- `scripts/check-docs`: backlog, ADR index, status, links.
- Dependency and static security scans in their own job; failure policy.
- gitleaks over the full history.
- ShellCheck on `scripts/`.
- `.github/dependabot.yml`.
- Not in scope: the container smoke test and image publishing (task 025, parked).

## Acceptance criteria

- Every new check fails on a deliberately bad input (shown in the pull request description) and passes on the repository.
- The existing job names `backend`, `frontend`, and `image` are unchanged. The new checks are separate jobs that run in parallel.
- `make check-quiet` passes.

## Outcome

Built. Each check, what it catches, how to run it locally, and the CI job that the ruleset should require:

| Check | What it catches | Locally | Required check (job) |
| --- | --- | --- | --- |
| `scripts/check-migration-roundtrip` | A migration added by the branch that has no working `down`; a `down` that leaves state `up` cannot rebuild; an `up` that fails on a database with data (the merge base is migrated and seeded with its own code first); seeds that fail after the migration. Irreversible on purpose: first line `# irreversible: <reason>`. | `make check-migration-roundtrip` (about 25 s with added migrations) | `migrations` |
| `scripts/check-docs` | Duplicate task or ADR numbers; a task or ADR file without its README row, or a row for a missing file, or rows out of order; a task without `Status:` or with a value that is not in use; a `Depends on:` task that does not exist; broken relative links and heading anchors in `README.md`, `AGENTS.md`, `SECURITY.md`, `docs/**/*.md` | `make check-docs` (also in `make check`) | `docs` |
| `shellcheck scripts/*` | Shell mistakes in `scripts/` (SC rules) | `make check-shell` (also in `make check`; needs `shellcheck`) | `shellcheck` |
| `mix hex.audit` | Retired Hex packages | `make check-security` | `security` |
| `mix deps.audit` (mix_audit) | Known advisories in Hex dependencies | `make check-security` | `security` |
| `mix sobelow --config` | Phoenix static security findings (injection, traversal, unsafe config) in `backend/lib` | `make check-security` | `security` |
| `npm audit --omit=dev --audit-level=high` | High or critical advisories in production npm dependencies (all dependencies: warning only) | `make check-security` | `security` |
| gitleaks (`scripts/check-secrets`) | A secret in any commit of the history, even one removed later | `make check-secrets` (needs Docker) | `secrets` |

All five new jobs are in `.github/workflows/ci.yml`, run in parallel with `backend`, `frontend`, and `image`, and keep `permissions: contents: read`. The `security` job is the only one that needs the advisory databases, so a registry outage fails it alone.

Findings on the current tree:

- `mix hex.audit`, `mix deps.audit`, `mix sobelow`: no findings. `npm audit`: 0 vulnerabilities, with and without development dependencies.
- `scripts/check-docs`: no problems in the current docs. A scratch copy with duplicate numbers, a missing row, an unknown status, a bad `Depends on`, and broken links failed every check.
- ShellCheck: one warning, `scripts/start` (SC2164, `cd` without `|| exit`). Fixed with `|| exit 1`; the script already ran without `set -e`, so this only makes a failed `cd` stop it.
- gitleaks: no leaks (the Phoenix dev/test key allowlist in `.gitleaks.toml` is unchanged).
- Roundtrip: all existing migrations are reversible, so none is marked irreversible and no old migration was changed.

Choices:

- New dev/test-only dependencies: `mix_audit` and `sobelow` (`runtime: false`).
- GitHub Actions stay pinned by major version tag (`@v4`), not by SHA. Dependabot is configured for `github-actions`, so a bump is a pull request either way.
- gitleaks runs from `ghcr.io/gitleaks/gitleaks:latest` on the whole history on every run.
- `check-migration-roundtrip`, `check-security`, and `check-secrets` are not part of `make check`: they need a base-branch compile, the network, or Docker.

Left out:

- A scheduled run of the audits (advisories appear without a code change); Dependabot and GitHub security alerts cover this for now.
- A license audit in CI (ADR 0019 did it once by hand).
- Rejecting edits to migrations that are already on `main`.
- Base image versions in `backend/Dockerfile` (`ARG`s) are not read by Dependabot.
- The container smoke test (task 025).

Follow-ups for the owner: add `migrations`, `docs`, `shellcheck`, `security`, and `secrets` to the required checks of the ruleset after the merge, and update the "three checks" wording in `AGENTS.md` and ADR 0010 then.
