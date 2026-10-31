# 018. Serve the web UI in production

- Status: parked (deployment work, nothing deployed)
- Area: `frontend/`, `backend/`, release
- Depends on: 012 (release and container)

## Goal

`make web` runs the UI only in development. Ship the built UI with the app.

## Scope

- Build with `npm run build` into `frontend/dist`.
- Serve `dist` from the Phoenix endpoint (`Plug.Static`) with a fallback to
  `index.html`. Or serve it from a CDN with `/api` proxied.
- Add the build step to the release and container (task 012).

## Acceptance criteria

- The production container serves the UI at `/` and the API at `/api`.
- A deep link such as `/?q=octopus` loads.
