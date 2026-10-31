# 0020. CI hardening: audits fail the build, migrations must roll back

- Status: Accepted
- Date: 2026-10-31

Extends [0010](0010-worktrees-and-pull-requests.md) (CI on every pull request).

## Context

The repository is public. CI ran the tests and the build, and nothing else: no scan of dependencies, no secret scan, no proof that a migration works on a database that is not empty, and no check that the backlog and the ADR index agree with the files. Several of these checks need the network (advisory databases), which tests must never do. See `docs/tasks/037-ci-hardening.md`.

## Decision

**Separate jobs.** Each new check runs in its own job in `.github/workflows/ci.yml`, in parallel with `backend`, `frontend`, and `image`: `migrations`, `docs`, `shellcheck`, `security`, `secrets`. A registry outage then fails `security` and nothing else, and test results stay visible. The existing job names do not change (the ruleset requires them). The new job names are added to the ruleset's required checks by the owner after the merge.

**Failure policy for dependency scans** (job `security`):

- `mix hex.audit`: any retired package fails. (Current Hex versions also list advisories there; any of them fails too.)
- `mix deps.audit` (mix_audit): any known advisory in any Hex dependency fails. mix_audit does not report a severity, so there is no "below high" for Hex. The dependency list is small; a false alarm is rare and cheap to handle. To accept an advisory, add its ID to `backend/.mix-audit-ignore` with a reason on the line above it, and remove it when the dependency is upgraded. Prefer upgrading.
- `mix sobelow --config` (`backend/.sobelow-conf`, `exit: "low"`): any finding fails. To accept one, use an inline `# sobelow_skip ["Check.Name"]` or `ignore:` in the config, each with a one-line reason next to it. The app is a JSON API, so checks about HTML templates do not apply, but they are not turned off: they simply find nothing.
- `npm audit --omit=dev --audit-level=high`: an advisory of high or critical severity in a production dependency fails. A second step runs `npm audit` for all dependencies and emits a warning annotation only: development dependencies are not shipped, and moderate or low advisories should not block unrelated work.
- Advisories appear without any code change, so a green `main` can make the next pull request red. Dependabot (below) and GitHub's security alerts are the early warning; there is no scheduled CI run.

**Secret scan** (job `secrets`): gitleaks, official image, whole git history (`fetch-depth: 0`), `.gitleaks.toml`, on every pull request and push. It uses `ghcr.io/gitleaks/gitleaks:latest` so the rule set stays current; a new gitleaks release that breaks the run is fixed in the config, not pinned away. A finding that was removed in a later commit still fails: the secret is in the history and must be rotated. `scripts/check-secrets` is the same command for local use.

**Migrations** (job `migrations`, `scripts/check-migration-roundtrip`): the migrations a branch adds (files not in the merge base with `origin/main`) must (1) apply to an empty database, (2) roll back and apply again, and (3) apply on top of a database that holds the data of the base branch: the merge base is checked out, migrated, and seeded with its own code. Old migrations are never rolled back, so irreversible history is not a problem. **Convention for an irreversible migration**: the first line of the file is `# irreversible: <reason>`. The check then skips the rollback of that file, and of the added migrations older than it, and says so. A migration without that line and without a working `down` fails with a message that names this convention. A marker without a reason fails. The reason is for the reviewer: an irreversible migration is a decision, so it should be visible in the diff.

**Docs** (job `docs`, `scripts/check-docs`): task and ADR numbers are unique, every file has its README row and the rows are in number order, `Status:` is one of the values in use, `Depends on:` names tasks that exist, and relative markdown links (and heading anchors in markdown targets) resolve. It also runs in `make check`.

**ShellCheck** (job `shellcheck`): `shellcheck scripts/*` with the version preinstalled on `ubuntu-latest`. A new warning is fixed, or silenced with a narrow `# shellcheck disable=SCxxxx` and a reason.

**Dependabot** (`.github/dependabot.yml`): weekly, for `mix` (`/backend`), `npm` (`/frontend`), `github-actions`, and `docker` and `docker-compose` (Dockerfile and compose file). Minor and patch updates of an ecosystem are grouped into one pull request; a major update is its own. GitHub Actions stay pinned by major version tag (`actions/checkout@v4`), not by commit SHA: the workflow has `contents: read` and no secrets, and a SHA pin would need Dependabot to bump it anyway, which it would do just as well for tags. Dependabot's pull requests go through the same CI and the same human merge as any other.

## Consequences

- A pull request can be red for a reason outside its diff (a new advisory). The fix is an upgrade, or a documented ignore.
- `migrations` compiles the base branch once more when a pull request adds migrations (about 10 to 60 seconds). It needs `fetch-depth: 0`.
- Local: `make check` and `make check-quiet` run `check-docs` and `check-shell` (skipped with a note when ShellCheck is not installed). `check-migration-roundtrip`, `check-security`, and `check-secrets` need a database, the network, or Docker, so they are separate targets that CI runs.
- The Dockerfile's base image versions come from `ARG`s that Dependabot cannot read. They are bumped by hand with `.tool-versions`.
- Not covered: the container smoke test (task 025, parked), a license audit in CI, and a scheduled scan.
