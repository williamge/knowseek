# 010. Telemetry and job dashboard

- Status: open
- Area: `KnowseekWeb.Telemetry`, contexts
- Depends on: none

## Goal

See what the service does: search latency, coverage outcomes, discovery
results per source, embedding latency and errors.

## Scope

- Emit `:telemetry` events from `Search.search/2`, `Discovery.run/2` (per
  source), `Embeddings.embed/1`, and `Documents.ingest/1`.
- Add metrics for them to `KnowseekWeb.Telemetry` so they show on the
  LiveDashboard at `/dev/dashboard`.
- Structured logging metadata (query hash, source, job id).

## Acceptance criteria

- Tests attach a telemetry handler and assert that events fire with the
  expected measurements and metadata.
