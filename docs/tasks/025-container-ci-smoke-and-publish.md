# 025. Boot the container in CI and publish the image

- Status: parked (deployment work, nothing deployed)
- Area: CI, `backend/Dockerfile`, `docker-compose.yml`
- Depends on: 012

## Goal

CI should prove that the image starts and serves traffic, and `main` should
produce an image that can be deployed.

## Context

Task 012 added `backend/Dockerfile`, the `app` compose profile, and a CI `image`
job that only runs `docker build`. Nothing in CI starts the container. A broken
`config/runtime.exs`, a failing `bin/migrate`, or the `force_ssl` redirect
would pass CI. The runtime image has no `curl`, so the container has no
`HEALTHCHECK`. Nothing publishes the image. See ADR 0014.

## Scope

- A CI job that starts Postgres (pgvector) and the image, waits for
  `GET /api/health` to return `{"status":"ok","database":"ok"}` (probe from the
  host or a sidecar), and fails with the container logs if it does not.
- A container health check that does not need `curl` (for example a small
  release command, or `wget` if you add it). Use it in compose.
- Publish the image from CI on pushes to `main`, never from a pull request.
  Choose a registry (GitHub Container Registry is the default choice), tag with
  the commit SHA and `main`, and write the choice and the permissions in an ADR.
- The smoke test must set `EMBEDDINGS_ADAPTER=hashing` (or run an Ollama
  service): the default is Ollama on the host (ADR 0016).
- The `image` job stays required for pull requests (see `AGENTS.md`).

## Acceptance criteria

- A CI run on a pull request starts the container and passes the health probe.
- A deliberately broken `runtime.exs` (try it on a throwaway branch) fails that
  job.
- After a merge to `main`, the image is in the registry with the SHA tag. Pull
  requests from forks cannot publish.
