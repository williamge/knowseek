# 013. OpenAPI spec for the API

- Status: open
- Area: web
- Depends on: none

## Goal

Give clients and future agents a machine-readable API contract.

## Scope

- Describe every endpoint with `open_api_spex` (or a hand-written
  `openapi.yaml`; pick one and say why).
- Serve the spec at `GET /api/openapi`.
- Validate request bodies against the spec where it is cheap.

## Acceptance criteria

- A test checks that every route in the router appears in the spec.
