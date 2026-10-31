# Architecture

## Overview

```mermaid
flowchart LR
    web([Web UI]) -->|/api, same origin| client([Client])
    client -->|POST /api/search| lookup[Knowseek.Lookup]
    lookup --> search[Knowseek.Search]
    search -->|full-text + vector| pg[(Postgres + pgvector)]
    search --> coverage{Coverage}
    coverage -->|sufficient| client
    coverage -->|partial / none| enqueue[Discovery.request]
    enqueue -->|Oban job| seek[SeekWorker]
    seek --> sources[[Discovery sources]]
    sources -->|candidates| ingest[Documents.ingest]
    ingest --> embed[Embeddings]
    ingest --> pg
```

A search returns right away with whatever the index has. Discovery runs in the background, so its results are available to later searches, not to the search that triggered it. (Pushing late results to the caller is a backlog task.)

## Components

All modules live in `backend/lib/knowseek/`.

| Module | Responsibility |
| --- | --- |
| `Knowseek.Lookup` | Entry point for a query. Searches, then requests discovery if coverage is not sufficient. |
| `Knowseek.Search` | Read-only hybrid search over chunks. Full-text (`tsvector`) and vector (cosine, HNSW) results are merged with reciprocal rank fusion. Chunks that are not relevant are dropped, so an uncovered query returns no hits. The rest are grouped by document: one hit per document, scored by its best chunk (never a sum), with up to `max_passages` other matching chunks in `passages` (`chunk_id`, `content`, `score`). |
| `Knowseek.Search.Coverage` | Pure heuristic that classifies a hit list as `:sufficient`, `:partial`, or `:none`. Each hit is one document, so it counts documents with a relevant, fresh hit. With `max_age_seconds`, it counts only documents whose `fetched_at` is within that many seconds. |
| `Knowseek.Documents` | The only write path into the index. Validates, canonicalizes the URL, chunks, embeds, and stores documents. Re-ingesting a URL updates it. A body that is long enough (`min_alias_body_length/0`) and already stored under another URL is not a new document: the URL becomes an alias of the stored one, and only that document's `fetched_at` moves (a document that has only a `urn:` URL takes the real URL instead). An alias URL that later serves a different body loses its alias and becomes a new document. An unchanged body at a document's own URL is not re-chunked or re-embedded, but the other fields and `fetched_at` are updated. See `docs/decisions/0013-url-canonicalization-and-aliases.md`. |
| `Knowseek.Documents.URL` | Pure URL canonicalization: lowercase scheme and host, no fragment, no default port, no tracking parameters (`utm_*`, `fbclid`, ...), sorted query. The tracking list lives there. |
| `Knowseek.Documents.Chunker` | Splits a body into chunks of at most ~1200 characters on paragraph and word boundaries. |
| `Knowseek.Embeddings` | Behaviour plus dispatcher for embedding providers. Takes `input_type: :document \| :query`. Adapters, selected by `EMBEDDINGS_ADAPTER`: `Embeddings.Ollama` (local `bge-m3` through Ollama, free; the default, ADR 0016), `Embeddings.Hashing` (local stand-in, no semantics; the opt-out and the adapter in tests), `Embeddings.Voyage` (Voyage AI API). |
| `Knowseek.Discovery` | Enqueues and runs discovery. Calls each configured `Discovery.Source` and ingests the candidates. |
| `Knowseek.Discovery.Source` | Behaviour for an external data source. |
| `Knowseek.Discovery.Sources.Wikipedia` | Searches English Wikipedia (MediaWiki API) and returns the plain text of the top 3 articles, capped at ~40k characters each. Skips disambiguation pages. |
| `KnowseekWeb.*` | JSON API. Controllers are thin and call the contexts above. |
| `frontend/` | Web UI (Vite, React, TypeScript). A client of the JSON API. See below. |

## Web UI

`frontend/` holds a single-page app. In development, Vite serves it and proxies `/api` to the Phoenix API, so the browser sees one origin and the API needs no CORS. The app keeps its state in the URL (`/?q=...&doc=...`), so searches can be shared.

Because the API does not yet tell callers when discovery finishes (task 006), the UI watches the index. After a search that enqueued discovery, it polls `GET /api/documents` for new document ids. When some arrive, it searches again and marks the new results. It stops when no new documents arrive for a while, or after 90 seconds. Task 006 replaces this polling. See `docs/decisions/0008-web-frontend.md`.

## Data model

```mermaid
erDiagram
    documents ||--o{ chunks : has
    documents ||--o{ document_aliases : has
    documents {
        uuid id
        text url "unique, canonical; urn:knowseek:sha256:... when none given"
        text title
        text body
        string source "e.g. manual, wikipedia"
        string content_hash "sha256 of body, indexed"
        timestamp published_at
        timestamp fetched_at
        jsonb metadata
    }
    document_aliases {
        uuid id
        uuid document_id "on delete cascade"
        text url "unique, canonical; another URL with the same body"
    }
    chunks {
        uuid id
        uuid document_id
        int position
        text content
        vector embedding "vector(1024), HNSW cosine index"
        tsvector search_vector "generated from content, GIN index"
    }
```

Oban stores its jobs in `oban_jobs` in the same database.

## Background jobs (Oban)

| Queue | Workers | Notes |
| --- | --- | --- |
| `discovery` | `Discovery.SeekWorker` | Unique per normalized query for 1 hour. 3 attempts. |

## Configuration

`backend/config/config.exs` holds the knobs:

- `Knowseek.Embeddings`: `adapter`, `dimensions` (must match the migration).
- `Knowseek.Embeddings.Ollama`: `base_url`, `model`, `max_batch_size`, `req_options`. Set from `OLLAMA_URL` and `OLLAMA_MODEL` in `config/runtime.exs`.
- `Knowseek.Embeddings.Voyage`: `model`, batch limits, `req_options`. `api_key` comes from `VOYAGE_API_KEY` in `config/runtime.exs`.
- `Knowseek.Search`: `default_limit`, `candidate_factor` (each ranked list fetches `limit * candidate_factor` chunks before grouping by document; 40, roughly the chunk count of a long Wikipedia article; manual documents have no size cap, so it is a heuristic, not a guarantee), `max_passages` (3), `min_similarity`, `min_strong_hits`, `max_age_seconds`. `min_similarity` is the relevance floor: a hit is returned and counted for coverage only if it matched the full-text search or has at least this cosine similarity. It depends on the embedding model (see `docs/decisions/0009-search-returns-only-relevant-hits.md`). `min_strong_hits` and `max_age_seconds` tune the coverage heuristic. `max_age_seconds` is the default freshness need for a search; `nil` ignores age. `POST /api/search` can override it per request; `null` there ignores age.
- `Knowseek.Discovery`: `sources` (list of modules). `config/test.exs` sets `sources: []`, so tests never call a real source. A test that needs a source passes `sources:` to `Discovery.run/2`.
- `Knowseek.Discovery.Sources.Wikipedia`: `base_url`, `limit`, `max_chars`, `user_agent`, `req_options` (tests put the `Req.Test` plug here).
- `Oban`: the `discovery` queue and the pruner.

Secrets (API keys) go in `config/runtime.exs`, read from environment variables.

## Deployment

The backend builds into a Mix release image (`backend/Dockerfile`). `docker compose --profile app up --build` runs it next to the compose Postgres. The container creates its database, runs the migrations (`Knowseek.Release.migrate/0`, which includes `CREATE EXTENSION vector`), and serves the API. Environment variables are listed in `README.md`. The image has no web UI yet (task 018). See `docs/decisions/0014-release-and-container.md`.

## Known limitations

- With `EMBEDDINGS_ADAPTER=hashing` (the opt-out), search matches words, not meaning. The default needs a running Ollama; when it is down, ingest and search return an error instead of falling back (ADR 0016).
- Chunks are not re-embedded when the embedding adapter changes.
- Wikipedia is the only discovery source, so discovery finds only encyclopedic data.
- No authentication and no users.
- The caller is not told when discovery finishes. The web UI polls for new documents instead.

Each limitation has a task in `docs/tasks/`.
