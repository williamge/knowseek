# 047. Dependency automation: daily Dependabot and a scheduled audit issue

- Status: done
- Area: `.github/dependabot.yml`, `.github/workflows/security-audit.yml`, `scripts/`, docs
- Depends on: none

## Goal

The owner is told the day a dependency advisory lands, and dependency update PRs arrive daily, not weekly. Policy: the 2026-11-05 update in `docs/decisions/0020-ci-hardening.md`.

## Context

On 2026-11-04 ecto 3.14.3 was released and, five hours later, advisory EEF-CVE-2026-118391 (ecto 3.14.2) was published. The CI `security` job went red within hours (`mix hex.audit` reads the Erlang Ecosystem Foundation/OSV feed), but nothing notified the owner: GitHub's advisory database did not have it (no Dependabot alerts, no Dependabot security PR), and Dependabot version updates ran weekly. Auto-merge was not chosen: a human merges.

## Acceptance criteria

- `mix` and `npm` run daily in `.github/dependabot.yml`; the other ecosystems stay weekly.
- A daily and manually dispatchable workflow audits `main` and opens, updates, or closes ONE issue labelled `security-audit`.
- The result handling is a script that runs without GitHub (`DRY_RUN=1`, a stub `gh`).
- `make check-quiet` passes; the required checks are green.

## Outcome

Built:

- `.github/dependabot.yml`: `mix` and `npm` are `interval: daily` (groups, limit 5 unchanged); `github-actions`, `docker`, `docker-compose` stay weekly. **No `cooldown` block**: the Dependabot options reference says version updates already get a default cooldown of 3 days, and that cooldown never applies to security updates, so an explicit value would repeat or shorten the default. Consequence to know: a brand-new release (such as ecto 3.14.3) is proposed by a version update only 3 days after its release; the audit issue is what tells you at once, and you can bump by hand.
- `scripts/check-security` (new; `make check-security` now calls it): runs `mix hex.audit`, `mix deps.audit --ignore-file .mix-audit-ignore`, `mix sobelow --config`, `npm audit --omit=dev --audit-level=high`, does not stop at the first failure, exits 1 if any failed. The old Makefile `&&` chain stopped at the first failure.
- `.github/workflows/security-audit.yml`: `schedule` (`17 6 * * *`) and `workflow_dispatch`, never on `pull_request`. `contents: read` at the top; `issues: write` on the single job only. Same toolchain and cache key as the CI `security` job; default checkout ref (the default branch). It runs `scripts/check-security`, captures the output, and passes exit status and output to the script below.
- `scripts/security-audit-issue <exit-status> <output-file>`: bash 3.2, ShellCheck clean. Fails + no open `security-audit` issue: create the label (red, with description; `--force`, so an existing label is fine) and the issue `Security audit failing on main` (date, commit SHA, first 60 lines of the output in a code block, run link, what to do). Fails + open issue: rewrite the body (one edit per run); add a comment only when the set of advisory IDs (stored as `<!-- advisories: ... -->` in the body) changed. Passes + open issue: comment `Audit passing again on <sha>` and close. Passes + no issue: nothing. `DRY_RUN=1` prints the writing `gh` commands and their body files; the two read-only `gh issue list/view` calls still run, so a stub `gh` on `PATH` makes it fully offline.
- **Exit code decision**: the workflow ends green after the issue is handled (the audit step records the status and emits a `::warning::`; only the issue step decides). Reason: the owner wants ONE notification, the issue; a red scheduled run would also e-mail on every failing day. It ends red only when the workflow itself breaks (setup, or `gh` failing), which is a different problem. Trade-off: a failing audit is not a red cross in the Actions list, only the warning annotation and the issue.
- Docs: ADR 0020 update paragraph, the AGENTS.md command row and CI paragraph, `docs/agent-brief.md` section 5 bullet. `scripts/*` is globbed by the `shellcheck` job and `make check-shell`, so the new scripts are covered; `check-docs` covers this file.

Left out: auto-merge (not chosen), a Dependabot `cooldown`, a pull request trigger for the audit, a test harness for the script (the manual checks below replace it), distinguishing a registry outage from a real advisory (an outage that fails the audit opens the issue; the next passing run closes it).

Limit: a scheduled workflow runs only from the default branch, so it cannot run before this PR is merged. Before merge it was verified with a stub `gh`, `actionlint` (Docker `rhysd/actionlint`), and ShellCheck (`koalaman/shellcheck`).

### Manual checks of `scripts/security-audit-issue` (no GitHub needed)

Stub `gh` on `PATH` (answers the two read-only calls, fails on anything else):

```bash
mkdir -p /tmp/stub && cat > /tmp/stub/gh <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") printf '%s' "${STUB_OPEN_NUMBER:-}" ;;
  "issue view") printf '%s\n' "${STUB_OLD_BODY:-}" ;;
  *) echo "STUB gh: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x /tmp/stub/gh
export PATH=/tmp/stub:$PATH DRY_RUN=1 GITHUB_SHA=0123456789abcdef0123456789abcdef01234567
scripts/check-security > /tmp/audit.out 2>&1; echo $?     # real audit output, 1 while ecto 3.14.2 is locked
```

1. **Create** (no open issue): `scripts/security-audit-issue 1 /tmp/audit.out`. Expect `gh label create security-audit --color B60205 ... --force`, then `gh issue create --title Security\ audit\ failing\ on\ main --label security-audit --body-file ...`, with the body printed (date, commit, the ecto advisory in a code block, what to do, `<!-- advisories: CVE-2026-118391,EEF-CVE-2026-118391,GHSA-cxjx-vmm2-qr8r -->`).
2. **Update** (open issue #7): `STUB_OPEN_NUMBER=7 STUB_OLD_BODY='<!-- advisories: CVE-1 -->' scripts/security-audit-issue 1 /tmp/audit.out`. Expect `gh issue edit 7 --body-file ...` and, because the advisory set differs, `gh issue comment 7 ...`. With `STUB_OLD_BODY='<!-- advisories: CVE-2026-118391,EEF-CVE-2026-118391,GHSA-cxjx-vmm2-qr8r -->'` only the `edit` appears.
3. **Close** (open issue #7, audit passes): `STUB_OPEN_NUMBER=7 scripts/security-audit-issue 0 /tmp/audit.out`. Expect `gh issue comment 7 ...` (`Audit passing again on 0123456789ab`) and `gh issue close 7 --reason completed`. Without `STUB_OPEN_NUMBER`: `Nothing to do.`

### Verification after merge (the parent does this; the workflow cannot run earlier)

1. While the ecto advisory is still open (ecto still 3.14.2 on `main`): `gh workflow run security-audit.yml`, then `gh run watch`. Expect a green run with the warning `Security audit failed`, and one new open issue `Security audit failing on main` with the label `security-audit`: `gh issue list --label security-audit`. Dispatching again must edit that issue, not open a second one.
2. After the ecto bump PR is merged: `gh workflow run security-audit.yml` again. Expect a green run, the comment `Audit passing again on <sha>`, and the issue closed.
