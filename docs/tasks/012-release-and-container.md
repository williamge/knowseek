# 012. Release build and app container

- Status: open
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
