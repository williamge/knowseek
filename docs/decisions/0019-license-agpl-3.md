# 0019. License: AGPL-3.0-only

- Status: Accepted
- Date: 2026-10-30

## Context

The repository is about to become public. A public repository without a license is "all rights reserved": nobody may legally use or change it. The owner wants people to read, run, and modify the code, but wants to prevent a closed, hosted fork of the service.

## Decision

License the repository under the GNU Affero General Public License v3.0, SPDX identifier `AGPL-3.0-only`. The owner chose AGPL-3.0, not "or later", so the conservative `-only` form is used. `LICENSE` holds the unmodified official text. `backend/mix.exs` (`package: [licenses: ...]`) and `frontend/package.json` (`license`) carry the identifier. Copyright holder: William Gelhar.

## Alternatives considered

- **MIT, Apache-2.0**: anyone can host a closed fork. This is what the owner wants to prevent.
- **GPL-3.0**: it does not cover use over a network, so a hosted modified service need not share its source. This is the gap AGPL closes.
- **Source-available (BSL, SSPL, Elastic)**: not open source. It limits use, hurts adoption, and the owner does not need the extra restrictions.
- **No license**: nobody can legally use the code.

## Consequences

- AGPL section 13: someone who runs a modified version as a network service must offer its source to the users of that service. Running the unmodified code, or modified code only for yourself, adds no duty.
- Relicensing later needs the consent of every contributor whose code is in the tree. Decide before accepting outside pull requests. Contributions are accepted under the same license (stated in the README). There is no CLA yet.
- Some of the code was written with AI coding assistants under the owner's direction.
- The web UI has no link to the source (section 13 matters for modified versions only, and none exist).
- Test fixtures with Wikipedia text are CC BY-SA 4.0, not AGPL. See `NOTICE`.

### Dependency license audit (2026-10-30)

Elixir: 35 packages in `backend/deps`, read from `licenses` in each `hex_metadata.config`.

| License | Packages |
| --- | --- |
| Apache-2.0 | 19 |
| MIT | 16 |

npm production dependencies (`license-checker --production`): `react`, `react-dom`, `scheduler` are MIT (3). The fourth entry is the frontend itself (it was `UNLICENSED` before this change). Development-only npm dependencies are not distributed in a build and were not audited.

Flagged packages (GPL-2.0-only, proprietary, SSPL, unknown or missing license): none. MIT and Apache-2.0 are compatible with AGPL-3.0 (Apache-2.0 only with GPL version 3, which AGPL-3.0 is).

Other things that are not in the repository:

- `pgvector/pgvector:pg17` (Docker image) runs Postgres (PostgreSQL License) and pgvector (PostgreSQL License). The repository pulls the image; it does not ship it. The Debian base images in `backend/Dockerfile` carry their own licenses; they were not audited.
- `bge-m3` (the Ollama embedding model, pulled by `scripts/ensure-ollama`): MIT, according to the BAAI/bge-m3 Hugging Face model card. It is not distributed in the repository.

## Not yet decided

- A CLA or DCO for outside contributions.
- Whether to move to "AGPL-3.0-or-later".
- A CONTRIBUTING file.
- Dual licensing (a commercial license) for people who cannot accept AGPL.
- A license audit of development-only dependencies and base images, and a CI check that keeps the audit current.
