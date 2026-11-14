# Knowseek

Knowseek is a service that answers "what is known about X?".

You send a query: a question, a subject, or a description of what you want to know about. Knowseek searches its index and returns what it already has. If the index does not cover the query well, Knowseek seeks new data from external sources, indexes it, and makes it available to later queries.

## Status and security

There is no authentication yet (task 009, parked). Do not expose the API to the public internet. `/dev/dashboard` exists only in the dev environment. To report a vulnerability, see [`SECURITY.md`](SECURITY.md).

## Status

Early skeleton. The end-to-end path works with local stand-ins:

- Ingest documents into a SQLite index (chunked and embedded): FTS5 for full text, sqlite-vec for vectors, one file per instance ([ADR 0030](docs/decisions/0030-sqlite-single-datastore.md)).
- Hybrid search (full-text + vector) with a coverage assessment.
- Weak coverage enqueues a discovery job. The job searches Wikipedia and indexes the top articles. For a question ("how do I fix a flat tire", or anything ending with `?`) it also searches Wikibooks, its Cookbook recipes first ("how do I cook eggs" finds *Cookbook:Hard Cooked Eggs*; ADR 0029).
- Embeddings come from a local Ollama (`bge-m3`) by default: real semantic search, free. `make setup` and `make start` check Ollama and pull the model. `EMBEDDINGS_ADAPTER=hashing` is the opt-out (matches words only, needs no Ollama). Voyage AI is the hosted option. See `.env.example`.
- A web UI (`frontend/`) searches and shows results as discovery adds them. Its `/stats` page shows what Knowseek recorded: searches per day by coverage, where each page came from, the database's size and the bytes discovery downloaded.
- A local record of your searches, of why each page was fetched (`origin`) and of the bytes discovery downloads ([ADR 0031](docs/decisions/0031-activity-record.md)). Your searches are stored in this instance's database only; `DELETE /api/searches` (or "Clear search history" on `/stats`) deletes them.
- Links from indexed pages to sites off an allowlist (`en.wikipedia.org`, `en.wikibooks.org`) are logged, not fetched. `/blocked-links` in the web UI shows them by domain ([ADR 0032](docs/decisions/0032-crawl-allowlist-and-blocked-links.md)).
- A background crawl reads the links of the pages your searches showed, while the instance is idle, scores them against your searches and lists the best on `/crawl` in the web UI ([ADR 0033](docs/decisions/0033-background-crawl.md)). The default mode, `preview`, reads and scores only. With `CRAWL_MODE=on` it also fetches the best candidate a minute while idle, at most 100 a day, after checking it again right before the fetch; the pages are stored with origin `background`, `/crawl` lists them under "Fetched", and `/stats` shows how often they filled a gap in your results (gain) and what each useful page cost to store ([#89](https://github.com/williamge/knowseek/issues/89)).

See [GitHub Issues](https://github.com/williamge/knowseek/issues) for the backlog.

## Quick start

Requirements: Elixir 1.20 / OTP 28 (see `.tool-versions`; `mise install` works), Node.js 22 or later for the web UI, and [Ollama](https://ollama.com) running on the host (`brew install ollama`, `brew services start ollama`). No database server and no Docker: the database is a SQLite file in `backend/data/`. `make setup` downloads the sqlite-vec extension once (pinned by SHA-256; built for macOS arm64 and Linux x86_64/aarch64). Docker is only for the release image.

```sh
make setup   # check Ollama, fetch deps and sqlite-vec, create + migrate the SQLite databases
make start   # API on http://localhost:4000 and web UI on http://localhost:4001, in one terminal; Ctrl-C stops both
make check   # what CI runs
```

The first run pulls the `bge-m3` model (about 1.2 GB). `make setup`, `make dev`, `make iex`, and `make start` run `scripts/ensure-ollama` first. It prints a short status line when all is well, and the fix when Ollama is missing or stopped. There is no silent fallback: if Ollama is down while the server runs, search and ingest return an error (HTTP 503 from the API), and a discovery job whose documents all fail to ingest is retried by Oban.

To run without Ollama, set `EMBEDDINGS_ADAPTER=hashing` in `.env`. Search then matches words, not meaning. After you switch an existing database between adapters, run `make db-reset`: the stored vectors are not comparable, and re-ingest skips unchanged documents ([#53](https://github.com/williamge/knowseek/issues/53)).

`make dev` (API) and `make web` (web UI) also run separately, on `$PORT` and `$PORT + 1` (default 4000 and 4001). `make worktree NAME=...` creates a second checkout next to this one with its own database files and port pair (see `AGENTS.md`).

Open the web UI, type a query, and press Enter. If the index covers the query weakly, the page keeps watching and adds new results when discovery finishes.

Try it:

```sh
curl -X POST localhost:4000/api/documents -H 'content-type: application/json' \
  -d '{"document": {"title": "sqlite-vec", "body": "sqlite-vec adds vector similarity search to SQLite."}}'

curl -X POST localhost:4000/api/search -H 'content-type: application/json' \
  -d '{"query": "sqlite vector search"}'
```

## Run in a container

The backend builds into a release image (`backend/Dockerfile`, Elixir 1.20 / OTP 28 on Debian trixie, with the Linux sqlite-vec build of its architecture). The `app` service in `docker-compose.yml` runs it. It sits behind a compose profile; development does not use compose.

```sh
docker compose --profile app up --build   # API on http://localhost:4000 (or $APP_PORT)
curl localhost:4000/api/health            # {"status":"ok","database":"ok"}
```

On start, the container creates its database file if it is missing, runs the migrations, then serves. The file is `/data/knowseek.db`, plus `_<workspace>` from `KNOWSEEK_WORKSPACE` in `.env` (for example `/data/knowseek_my-branch.db`), in the `appdata` volume. The API listens on `127.0.0.1` only, on `$APP_PORT` (default 4000). Set `APP_PORT` when `make dev` runs too.

**One app container per compose project.** The compose project is `knowseek` for every worktree, and so is the `app` service. Running `docker compose --profile app up` in a second worktree replaces the first worktree's `app` container. The image tag (`knowseek-app:<workspace>`) and the database file follow the workspace, so nothing is corrupted: the new container runs the new worktree's code against its own file. To run two at once you need two compose projects, which this repository does not set up.

Stop and clean up:

```sh
docker compose --profile app stop app   # stop the app, keep the container
docker compose --profile app rm -sf app # remove the app container only
docker compose --profile app down       # remove the app container (the appdata volume is kept)
```

Never use `docker compose down -v`: it deletes the `appdata` volume with every database file in it.

The web UI is not in the image yet (task 018). The container serves only the JSON API.

### Environment variables

The release reads these in `backend/config/runtime.exs`. In `docker-compose.yml`, the first five are already set.

| Variable | Required | Default | Example |
| --- | --- | --- | --- |
| `DATABASE_PATH` | yes (prod) | the image sets `/data/knowseek.db`; compose sets `/data/knowseek_<workspace>.db` | `/var/lib/knowseek/knowseek.db` |
| `SECRET_KEY_BASE` | yes (prod) | none; compose has an insecure local-only default | output of `mix phx.gen.secret` |
| `PHX_SERVER` | yes in a release | none; `bin/server` and compose set `true` | `true` |
| `PHX_HOST` | no | `example.com`; compose uses `localhost` | `knowseek.example.com` |
| `PORT` | no | `4000` | `4000` |
| `POOL_SIZE` | no | `10` | `20` |
| `DNS_CLUSTER_QUERY` | no | off | `knowseek.internal` |
| `EMBEDDINGS_ADAPTER` | no | `ollama` | `hashing`, `voyage` |
| `OLLAMA_URL` | no | `http://localhost:11434`; compose reads `APP_OLLAMA_URL`, default `http://host.docker.internal:11434` | `http://host.docker.internal:11434` |
| `OLLAMA_MODEL` | no | `bge-m3` | `bge-m3` |
| `VOYAGE_API_KEY` | with `voyage` | none | `pa-...` |
| `VOYAGE_MODEL` | no | `voyage-3.5` | `voyage-3.5` |
| `TRUSTED_PROXIES` | no | none: `X-Forwarded-For` is ignored | `10.0.0.0/8,fd00::/8` |
| `SEC_USER_AGENT` | no | `Knowseek/0.1 (self-hosted instance)` | `My Company admin@example.com` |
| `BALLDONTLIE_API_KEY` | for the NBA card | none: no NBA card | the key from your free balldontlie account |
| `CRAWL_MODE` | no | `preview` | `off`, `preview`, `on` |
| `CRAWL_IDLE_SECONDS` | no | `600` | `60` |

`SEC_USER_AGENT` is the User-Agent of the company card's requests to `data.sec.gov`. The SEC asks every automated user to say who it is (a name and a contact address) and blocks undeclared tools with HTTP 403; the default is accepted today, but a deployment that serves other people should set its own. With a block the company cards go `stale` or `unavailable` and the log says so once. No key and no account are needed.

`BALLDONTLIE_API_KEY` turns on the NBA team card. Sign up for a free account at [balldontlie.io](https://www.balldontlie.io) and copy the key from the dashboard; balldontlie's terms do not let you share it. The free tier allows 5 requests a minute: enough for a few cards, and a live game refreshes every 30 s. Without the key a team query has no card ([ADR 0028](docs/decisions/0028-nba-card-source.md)).

`TRUSTED_PROXIES` and `BALLDONTLIE_API_KEY` are also forwarded by compose. Compose only: `APP_PORT` (host port on 127.0.0.1, default 4000), `APP_OLLAMA_URL`. They can go in `.env`, which compose reads.

Notes:

- Production sets `force_ssl` with `x_forwarded_proto`: a request over plain HTTP for any host other than `localhost` or `127.0.0.1` gets a redirect to HTTPS. `GET /api/health` is excluded, so a probe can reach it by IP or service name over HTTP. Run the container behind a TLS-terminating proxy that sets `X-Forwarded-Proto`.
- The database is one SQLite file (WAL mode: the `-wal` and `-shm` files beside it belong to it). Keep it on a local disk, not a network file system. Back it up with `sqlite3 <file> "VACUUM INTO 'backup.db'"` or the backup API, not by copying the file while the app runs. The image ships the sqlite-vec extension in the release (`priv/sqlite_vec/vec0.so`).
- Ollama on the host: Docker Desktop reaches it at `host.docker.internal`. On Linux, start Ollama with `OLLAMA_HOST=0.0.0.0` so it listens beyond loopback.
- The container never reads `.env` from the repository. Compose does, to fill `${...}` values.

## API

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/health` | Liveness and database check |
| `POST` | `/api/search` | `{query, limit?, max_age_seconds?}` → hits, coverage, discovery status. One hit per document: the best matching chunk's fields (`chunk_id`, `content`, `score`, ranks, `similarity`) plus `fetched_at` (when Knowseek last saw the page), `source_updated_at` (when the source says the page was last edited, or `null`), the document's license fields (below) and `passages`, up to 3 other matching chunks (`chunk_id`, `content`, `score`). Hits are only relevant, so a query that the index does not cover returns no hits. A document's `score` is its best chunk's score times a bounded prior from its Wikipedia page views (at most +30%, ADR 0018). With `max_age_seconds`, only documents fetched within that many seconds count toward coverage. `null` ignores age. |
| `GET` | `/api/cards?q=<query>` | The card of live facts for what the query is about (an NBA team: record, the game in progress or the last and next games; balldontlie data, only when `BALLDONTLIE_API_KEY` is set: [ADR 0028](docs/decisions/0028-nba-card-source.md). A place asked for with `weather in <place>` or `<place> weather`: current weather and a 5-day forecast; Open-Meteo data, non-commercial use, [ADR 0022](docs/decisions/0022-weather-card-terms-and-intent.md). A public company that has an SEC Central Index Key (`nvda`, `nvidia`, `apple`): who it is, its shares outstanding and its latest 10-K, 10-Q and 8-K filings, from the SEC's EDGAR, with no price: [ADR 0021](docs/decisions/0021-company-card-source.md)). Cache-only: it never calls balldontlie, Open-Meteo, the SEC or Wikidata, so poll it. `{data: {status, entity, alternatives, card, as_of, refresh_after_ms}}`. `status` is `pending` (the entity or the card is not cached yet: ask again in `refresh_after_ms`, 0.7 s), `fresh`, `stale` (cached data past its TTL, with its old `as_of`), `unavailable` (a source failed and nothing was ever cached) or `none` (the query names no entity with a card, for example `westchester knicks`, `nvda`, `tokyo` alone: show nothing). `entity` and each of the `alternatives` (other entities of the same kind, at most 5) are `{id, label, description, kind, wikipedia_title}`; `entity` is `null` while pending and for `none`. `card` is `null` unless `fresh` or `stale`, else `{type: "sports_team", title, facts}` with `facts` `{source, league, record, live, last_game, next_game}` (`live`: `opponent`, `home_away`, `team_score`, `opponent_score`, `period`, `clock`, `status_text`; `last_game`: `date`, `opponent`, `home_away`, `result`, `team_score`, `opponent_score`; `next_game`: `date`, `opponent`, `home_away`). `as_of` is when the data was fetched (UTC). For a company the card is `{type: "company", title, facts}` with `facts` `{source, source_url, legal_name, cik, listings, industry, category, fiscal_year_end, shares_outstanding, filings}` (`listings`: `[{ticker, exchange}]` as the SEC gives them; `fiscal_year_end`: `{month, day}`; `shares_outstanding`: `{value, as_of}` or `null`; `filings`: the latest five 10-K, 10-Q and 8-K (20-F, 40-F and 6-K for a foreign filer), `[{form, filed, report_date, items, description, url}]`; each of the others can be `null`). For a place the card is `{type: "weather", title, facts}` with `facts` `{source, source_url, timezone, utc_offset_seconds, observed_at, current, daily}` in metric units (`current`: `temperature_c`, `apparent_temperature_c`, `humidity_percent`, `precipitation_mm`, `wind_speed_kmh`, `wind_direction_deg`, `is_day`, `weather_code`, `condition`, `icon`; `daily`: `[{date, high_c, low_c, precipitation_probability_percent, weather_code, condition, icon, sunrise, sunset}]`, today first); the UI must show the "Weather data by Open-Meteo.com" credit. `tokyo` alone is `none`; a team asked for with the weather words gets its team card. `400` without `q`. |
| `GET` | `/api/documents` | Recently fetched documents, without their `body`. Use `GET /api/documents/:id` for the full text. |
| `GET` | `/api/documents/:id` | One document |
| `POST` | `/api/documents` | `{document: {body, title?, url?, license?, attribution?, modified?, share?}}` manual ingest. The `url` is canonicalized. A body already stored under another URL returns that document (only its `fetched_at` moves), and the URL becomes its alias. Without license fields the document is unknown and not shared. |
| `GET` | `/api/stats` | The numbers over the local record (ADR 0031): `searches` (`total`, and `days`: the last 30 UTC days with their `sufficient`, `partial` and `none` counts), `pages` (documents by `origin`), `disk_bytes` (the database file), `network` (bytes per UTC day and discovery source), `hit_share` (`background_pages`, `hit_pages`), `gain` (ADR 0033: `pages`, the background pages that showed up where fewer than 3 other pages did; `searches`, the searches in the last 30 days where that happened; `window_searches`, all searches in those 30 days) and `crawl` (the background crawl, ADR 0033: `mode`, `pages_per_day`, `fetched_today`, `fetched`, `links_read`, `candidates`, `stored_bytes`, the estimated bytes of all background pages). |
| `GET` | `/api/crawl` | The background crawl (ADR 0033): `{data: {mode, pages_per_day, fetched_today, bar, next, fetched}}`. `next` lists the candidates in the order they would be fetched, `fetched` the last 50 background pages, newest first; each entry has `title`, `description`, `url`, `source` (`document_id`, `title`, `url`, `queries`: the page whose links were read, and the searches that showed it) the score parts `interest`, `novelty`, `gap`, `shared`, `shared_count`, `score`, and `document_id`, `fetched_at`, `stored_bytes` and `hit` (null or false in `next`; in `fetched`, `title` and `url` are the stored page's and `hit` says a logged search showed it). Read-only; it shows page titles and the queries of the source pages, so it is as private as the search log. |
| `DELETE` | `/api/searches` | Deletes every logged search; answers `{data: {deleted}}`. |
| `GET` | `/api/blocked-links` | The blocked-link log by domain: `allowed_hosts`, `total_domains`, `total_links` and up to 200 `domains` (`host`, `links`, `pages`, `times_seen`, `first_seen_at`, `example_url`), most linking pages first. |
| `POST` | `/api/blocked-links/backfill` | No body. Enqueues one job per indexed Wikipedia or Wikibooks page that logs its blocked links; answers `202` with `{data: {enqueued}}`. |

Documents and hits carry license fields ([ADR 0026](docs/decisions/0026-per-document-license-fields.md)): `license` (SPDX id, `LicenseRef-unknown` when not known), `attribution` (`{url, credit, authors}` or `null`), `modified` (the text differs from the source's) and `share` (`full`, `pointer` or `none`). Wikipedia and Wikibooks documents are `CC-BY-SA-4.0`, credited to "Wikipedia" or "Wikibooks", `modified: true`, `share: full`.

Documents also carry `origin` (`search`, `background` or `manual`) and `origin_query` (the normalized query whose discovery fetched the page, or `null`): why the page first entered the index. Both are set once; `POST /api/documents` always stores `manual`. Pages indexed before this was recorded are `search` with no query ([ADR 0031](docs/decisions/0031-activity-record.md)).

**Rate limits.** `GET /api/cards`, `POST /api/search` and `POST /api/documents` are limited per client address, each with its own budget: a burst, then a steady rate (defaults: cards 120 then 2 a second, search and documents 30 then one every 2 s; `backend/config/config.exs`). Over the limit the answer is `429 Too Many Requests` with `{"errors": {"detail": "Too many requests"}}` and a `Retry-After` header in seconds, and nothing else happens: no search, no ingest, no job. `GET /api/health` and the reads of `/api/documents` are not limited. The client is the socket address. Request bodies over 1 MB are answered `413`. Behind a reverse proxy, set `TRUSTED_PROXIES` (see above); without it `X-Forwarded-For` is ignored, so a client cannot choose its own address, and every client behind the proxy shares one budget. The same holds for `docker compose --profile app up`: the published Docker port hides the client address, so all clients share one budget until `TRUSTED_PROXIES` (read from `.env`) names the proxy. The limit also does not stop a flood from many addresses. See [ADR 0023](docs/decisions/0023-rate-limiting-anonymous-endpoints.md).

## License

Copyright (C) 2026 William Gelhar. Knowseek is licensed under the [GNU Affero General Public License v3.0 only](LICENSE) (`AGPL-3.0-only`). If you run a modified version as a network service, you must offer its source code to the users of that service (AGPL section 13). Contributions are accepted under the same license. See [ADR 0019](docs/decisions/0019-license-agpl-3.md).

### Third-party content

Test fixtures contain excerpts of Wikipedia and Wikibooks (CC BY-SA 4.0) and Wikidata (CC0). See [`NOTICE`](NOTICE).

What Knowseek may store, embed and share from each source, and under which license: [`docs/notes/storage-and-licenses.md`](docs/notes/storage-and-licenses.md).

## Documentation

- [`AGENTS.md`](AGENTS.md): how to work in this repo (for humans and coding agents)
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): components, data flow, data model
- [`docs/decisions/`](docs/decisions/): architecture decision records
- [`docs/notes/`](docs/notes/): research findings
- [GitHub Issues](https://github.com/williamge/knowseek/issues): the backlog
- [`frontend/README.md`](frontend/README.md): the web UI
