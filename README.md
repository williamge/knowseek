# Knowseek

Knowseek is a service that answers "what is known about X?" and keeps you informed about X over time.

You send a query: a question, a topic, or a description of what you want to follow. Knowseek searches its index and returns what it already has. If the index does not cover the query well, Knowseek seeks new data from external sources, indexes it, and makes it available to later queries. Topics that you subscribe to are refreshed on a schedule.

## Status

Early skeleton. The end-to-end path works with local stand-ins:

- Ingest documents into a Postgres + pgvector index (chunked and embedded).
- Hybrid search (full-text + vector) with a coverage assessment.
- Weak coverage enqueues a discovery job. **No real discovery sources exist yet.**
- Embeddings come from a local hashing stand-in, not a real model.

See [`docs/tasks/`](docs/tasks/) for the backlog.

## Quick start

Requirements: Docker, Elixir 1.20 / OTP 28 (see `.tool-versions`; `mise install` works).

```sh
make setup   # start Postgres, fetch deps, create + migrate databases
make dev     # API on http://localhost:4000 (or $CONDUCTOR_PORT)
make check   # what CI runs
```

Try it:

```sh
curl -X POST localhost:4000/api/documents -H 'content-type: application/json' \
  -d '{"document": {"title": "pgvector", "body": "pgvector adds vector similarity search to Postgres."}}'

curl -X POST localhost:4000/api/search -H 'content-type: application/json' \
  -d '{"query": "postgres vector search"}'
```

## API

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/health` | Liveness and database check |
| `POST` | `/api/search` | `{query, limit?, max_age_seconds?}` → hits, coverage, discovery status. With `max_age_seconds`, only documents fetched within that many seconds count toward coverage. `null` ignores age. |
| `GET` | `/api/documents` | Recently fetched documents |
| `GET` | `/api/documents/:id` | One document |
| `POST` | `/api/documents` | `{document: {body, title?, url?}}` manual ingest |
| `GET` | `/api/topics` | Topics you follow |
| `POST` | `/api/topics` | `{topic: {query, refresh_interval_seconds?, max_age_seconds?}}`. With `max_age_seconds`, a refresh seeks new data only when too few documents were fetched within that time. Without it, every refresh seeks new data. |
| `DELETE` | `/api/topics/:id` | Stop following a topic |

## Documentation

- [`AGENTS.md`](AGENTS.md): how to work in this repo (for humans and coding agents)
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): components, data flow, data model
- [`docs/decisions/`](docs/decisions/): architecture decision records
- [`docs/tasks/`](docs/tasks/): the task backlog
