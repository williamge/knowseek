# Knowseek

Knowseek is a service that answers "what is known about X?".

You send a query: a question, a subject, or a description of what you want to know about. Knowseek searches its index and returns what it already has. If the index does not cover the query well, Knowseek seeks new data from external sources, indexes it, and makes it available to later queries.

## Status and security

There is no authentication yet (task 009, parked). Do not expose the API to the public internet. `/dev/dashboard` exists only in the dev environment. Postgres is published on `127.0.0.1` only. To report a vulnerability, see [`SECURITY.md`](SECURITY.md).

## Status

Early skeleton. The end-to-end path works with local stand-ins:

- Ingest documents into a Postgres + pgvector index (chunked and embedded).
- Hybrid search (full-text + vector) with a coverage assessment.
- Weak coverage enqueues a discovery job. The job searches Wikipedia and indexes the top articles.
- Embeddings come from a local Ollama (`bge-m3`) by default: real semantic search, free. `make setup` and `make start` check Ollama and pull the model. `EMBEDDINGS_ADAPTER=hashing` is the opt-out (matches words only, needs no Ollama). Voyage AI is the hosted option. See `.env.example`.
- A web UI (`frontend/`) searches and shows results as discovery adds them.

See [`docs/tasks/`](docs/tasks/) for the backlog.

## Quick start

Requirements: Docker, Elixir 1.20 / OTP 28 (see `.tool-versions`; `mise install` works), Node.js 22 or later for the web UI, and [Ollama](https://ollama.com) running on the host (`brew install ollama`, `brew services start ollama`).

```sh
make setup   # start Postgres, check Ollama, fetch deps, create + migrate databases
make start   # API on http://localhost:4000 and web UI on http://localhost:4001, in one terminal; Ctrl-C stops both
make check   # what CI runs
```

The first run pulls the `bge-m3` model (about 1.2 GB). `make setup`, `make dev`, `make iex`, and `make start` run `scripts/ensure-ollama` first. It prints a short status line when all is well, and the fix when Ollama is missing or stopped. There is no silent fallback: if Ollama is down while the server runs, search and ingest return an error (HTTP 503 from the API), and a discovery job whose documents all fail to ingest is retried by Oban. `make worktree` gives task worktrees `EMBEDDINGS_ADAPTER=hashing` in `.env` unless it is already set.

To run without Ollama, set `EMBEDDINGS_ADAPTER=hashing` in `.env`. Search then matches words, not meaning. After you switch an existing database between adapters, run `make db-reset`: the stored vectors are not comparable, and re-ingest skips unchanged documents (task 017).

`make dev` (API) and `make web` (web UI) also run separately, on `$CONDUCTOR_PORT` and `$CONDUCTOR_PORT + 1`.

Open the web UI, type a query, and press Enter. If the index covers the query weakly, the page keeps watching and adds new results when discovery finishes.

Try it:

```sh
curl -X POST localhost:4000/api/documents -H 'content-type: application/json' \
  -d '{"document": {"title": "pgvector", "body": "pgvector adds vector similarity search to Postgres."}}'

curl -X POST localhost:4000/api/search -H 'content-type: application/json' \
  -d '{"query": "postgres vector search"}'
```

## Run in a container

The backend builds into a release image (`backend/Dockerfile`, Elixir 1.20 / OTP 28 on Debian trixie). The `app` service in `docker-compose.yml` runs it next to the Postgres service. It sits behind a compose profile, so `make dev` and `make db-up` still start only Postgres.

```sh
docker compose --profile app up --build   # API on http://localhost:4000 (or $APP_PORT)
curl localhost:4000/api/health            # {"status":"ok","database":"ok"}
```

On start, the container creates its database if it is missing, runs the migrations, then serves. The database is `knowseek_prod`, plus `_<workspace>` from `KNOWSEEK_WORKSPACE` in `.env` (for example `knowseek_prod_task-014-one-hit`; dashes work), or `$APP_DB_NAME` if you set it. The API listens on `127.0.0.1` only, on `$APP_PORT` (default 4000). Set `APP_PORT` when `make dev` runs too.

**One app container per compose project.** The compose project is `knowseek` for every worktree, and so is the `app` service. Running `docker compose --profile app up` in a second worktree replaces the first worktree's `app` container. The image tag (`knowseek-app:<workspace>`) and the database follow the workspace, so nothing is corrupted: the new container runs the new worktree's code against its own database. To run two at once you need two compose projects, which this repository does not set up.

Stop and clean up:

```sh
docker compose --profile app stop app   # stop the app, keep the container
docker compose --profile app rm -sf app # remove the app container only
docker compose --profile app down       # remove app and db containers (volume kept)
```

`make db-down` runs the last command. Plain `docker compose down` does not: it skips services of an inactive profile, stops `db`, and leaves a running `app` container without a database. Never use `docker compose down -v`: it deletes the Postgres volume with every database in it.

The web UI is not in the image yet (task 018). The container serves only the JSON API.

### Environment variables

The release reads these in `backend/config/runtime.exs`. In `docker-compose.yml`, the first five are already set for the compose database.

| Variable | Required | Default | Example |
| --- | --- | --- | --- |
| `DATABASE_URL` | yes (prod) | none; compose sets `ecto://postgres:postgres@db/$APP_DB_NAME` | `ecto://user:pass@host/knowseek` |
| `SECRET_KEY_BASE` | yes (prod) | none; compose has an insecure local-only default | output of `mix phx.gen.secret` |
| `PHX_SERVER` | yes in a release | none; `bin/server` and compose set `true` | `true` |
| `PHX_HOST` | no | `example.com`; compose uses `localhost` | `knowseek.example.com` |
| `PORT` | no | `4000` | `4000` |
| `POOL_SIZE` | no | `10` | `20` |
| `ECTO_IPV6` | no | off | `true` |
| `DNS_CLUSTER_QUERY` | no | off | `knowseek.internal` |
| `EMBEDDINGS_ADAPTER` | no | `ollama` | `hashing`, `voyage` |
| `OLLAMA_URL` | no | `http://localhost:11434`; compose reads `APP_OLLAMA_URL`, default `http://host.docker.internal:11434` | `http://host.docker.internal:11434` |
| `OLLAMA_MODEL` | no | `bge-m3` | `bge-m3` |
| `VOYAGE_API_KEY` | with `voyage` | none | `pa-...` |
| `VOYAGE_MODEL` | no | `voyage-3.5` | `voyage-3.5` |
| `TRUSTED_PROXIES` | no | none: `X-Forwarded-For` is ignored | `10.0.0.0/8,fd00::/8` |

Compose only: `APP_PORT` (host port on 127.0.0.1, default 4000), `APP_DB_NAME` (default `knowseek_prod_<workspace>`), `APP_OLLAMA_URL`. They can go in `.env`, which compose reads.

Notes:

- Production sets `force_ssl` with `x_forwarded_proto`: a request over plain HTTP for any host other than `localhost` or `127.0.0.1` gets a redirect to HTTPS. `GET /api/health` is excluded, so a probe can reach it by IP or service name over HTTP. Run the container behind a TLS-terminating proxy that sets `X-Forwarded-Proto`.
- Migration `create_index_tables` runs `CREATE EXTENSION IF NOT EXISTS vector`. The compose database user is a superuser, so this works. On a managed Postgres, enable the `vector` extension first (or use a user that may create it), and create the database yourself if the user cannot.
- Ollama on the host: Docker Desktop reaches it at `host.docker.internal`. On Linux, start Ollama with `OLLAMA_HOST=0.0.0.0` so it listens beyond loopback.
- The container never reads `.env` from the repository. Compose does, to fill `${...}` values.

## API

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/health` | Liveness and database check |
| `POST` | `/api/search` | `{query, limit?, max_age_seconds?}` → hits, coverage, discovery status. One hit per document: the best matching chunk's fields (`chunk_id`, `content`, `score`, ranks, `similarity`) plus `fetched_at` (when Knowseek last saw the page), `source_updated_at` (when the source says the page was last edited, or `null`) and `passages`, up to 3 other matching chunks (`chunk_id`, `content`, `score`). Hits are only relevant, so a query that the index does not cover returns no hits. A document's `score` is its best chunk's score times a bounded prior from its Wikipedia page views (at most +30%, ADR 0018). With `max_age_seconds`, only documents fetched within that many seconds count toward coverage. `null` ignores age. |
| `GET` | `/api/cards?q=<query>` | The card of live facts for what the query is about (an NBA team today: record, the game in progress or the last and next games, injuries; ESPN data). Cache-only: it never calls ESPN or Wikidata, so poll it. `{data: {status, entity, alternatives, card, as_of, refresh_after_ms}}`. `status` is `pending` (the entity or the card is not cached yet: ask again in `refresh_after_ms`, 0.7 s), `fresh`, `stale` (cached data past its TTL, with its old `as_of`), `unavailable` (a source failed and nothing was ever cached) or `none` (the query names no entity with a card, for example `westchester knicks`, `nvda`, `weather in tokyo`: show nothing). `entity` and each of the `alternatives` (other entities of the same kind, at most 5) are `{id, label, description, kind, wikipedia_title}`; `entity` is `null` while pending and for `none`. `card` is `null` unless `fresh` or `stale`, else `{type: "sports_team", title, facts}` with `facts` `{source, league, record, live, last_game, next_game, injuries}` (`live`: `opponent`, `home_away`, `team_score`, `opponent_score`, `period`, `clock`, `status_text`; `last_game`: `date`, `opponent`, `home_away`, `result`, `team_score`, `opponent_score`; `next_game`: `date`, `opponent`, `home_away`; `injuries`: `[{player, status}]`). `as_of` is when the data was fetched (UTC). `400` without `q`. |
| `GET` | `/api/documents` | Recently fetched documents, without their `body`. Use `GET /api/documents/:id` for the full text. |
| `GET` | `/api/documents/:id` | One document |
| `POST` | `/api/documents` | `{document: {body, title?, url?}}` manual ingest. The `url` is canonicalized. A body already stored under another URL returns that document (only its `fetched_at` moves), and the URL becomes its alias. |

**Rate limits.** `GET /api/cards`, `POST /api/search` and `POST /api/documents` are limited per client address, each with its own budget: a burst, then a steady rate (defaults: cards 120 then 2 a second, search and documents 30 then one every 2 s; `backend/config/config.exs`). Over the limit the answer is `429 Too Many Requests` with `{"errors": {"detail": "Too many requests"}}` and a `Retry-After` header in seconds, and nothing else happens: no search, no ingest, no job. `GET /api/health` and the reads of `/api/documents` are not limited. The client is the socket address. Behind a reverse proxy, set `TRUSTED_PROXIES` (see above); without it `X-Forwarded-For` is ignored, so a client cannot choose its own address. See [ADR 0023](docs/decisions/0023-rate-limiting-anonymous-endpoints.md).

## License

Copyright (C) 2026 William Gelhar. Knowseek is licensed under the [GNU Affero General Public License v3.0 only](LICENSE) (`AGPL-3.0-only`). If you run a modified version as a network service, you must offer its source code to the users of that service (AGPL section 13). Contributions are accepted under the same license. See [ADR 0019](docs/decisions/0019-license-agpl-3.md).

### Third-party content

Test fixtures contain excerpts of Wikipedia (CC BY-SA 4.0) and Wikidata (CC0). See [`NOTICE`](NOTICE).

## Documentation

- [`AGENTS.md`](AGENTS.md): how to work in this repo (for humans and coding agents)
- [`docs/WORKING-WITH-AGENTS.md`](docs/WORKING-WITH-AGENTS.md): how to run several agents in parallel, with prompt templates in [`docs/agent-brief.md`](docs/agent-brief.md)
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): components, data flow, data model
- [`docs/decisions/`](docs/decisions/): architecture decision records
- [`docs/tasks/`](docs/tasks/): the task backlog
- [`frontend/README.md`](frontend/README.md): the web UI
