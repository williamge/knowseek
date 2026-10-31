# 012. Release build and app container

- Status: done
- Area: build, `docker-compose.yml`
- Depends on: none

## Goal

Run the whole service with `docker compose up`, as a step toward deployment.

## Scope

- `mix phx.gen.release --docker` (adjust for the `backend/` directory).
- Add an `app` service to `docker-compose.yml` behind a compose profile so
  `make dev` keeps using only `db`.
- Run migrations on start (release `migrate` command).
- Document the required env vars in `README.md`.

## Acceptance criteria

- `docker compose --profile app up` serves `/api/health` with `ok`.
- CI builds the image (no push).

## Outcome

Built:

- `backend/Dockerfile` (from `mix phx.gen.release --docker`, builder `hexpm/elixir:1.20.4-erlang-28.5.0.6-debian-trixie-20260918-slim`, runtime `debian:trixie-20260918-slim`), `backend/.dockerignore`, `backend/rel/overlays/bin/{server,migrate}`, and `Knowseek.Release` (creates the database if missing, then migrates) with a test.
- `app` service in `docker-compose.yml` behind `profiles: [app]`. `make dev` still starts only `db`. Host port `APP_PORT`, database `APP_DB_NAME`.
- CI `image` job: `docker build backend`, no push.
- README: how to run and a table of every environment variable. `.env.example` lists `APP_*` and `APP_OLLAMA_URL`.
- ADR [0014](../decisions/0014-release-and-container.md).

Left out:

- The web UI is not in the image (task 018).
- No registry push, no deployment target, no container healthcheck (no `curl` in the runtime image).
- No release smoke test in CI (the job only builds).

Follow-ups: publish the image from CI on `main`; serve the built frontend (task 018); add a CI job that boots the container against Postgres and probes `/api/health`.
