# Architecture decision records

One file per decision: `NNNN-short-title.md`, numbered in order. Copy
`0000-template.md`. Do not edit an accepted ADR to change the decision;
write a new ADR that supersedes it and set the old one's status to
`Superseded by NNNN`.

| ADR | Decision |
| --- | --- |
| [0001](0001-elixir-phoenix-backend.md) | Elixir + Phoenix for the backend |
| [0002](0002-postgres-pgvector.md) | Postgres + pgvector as the single datastore (superseded by 0030) |
| [0003](0003-hybrid-search.md) | Hybrid search with reciprocal rank fusion |
| [0004](0004-embeddings.md) | Pluggable embeddings, fixed at 1024 dimensions |
| [0005](0005-per-workspace-databases.md) | One database per checkout (Conductor removed 2026-11-05; SQLite files in each checkout since 0030) |
| [0006](0006-freshness-aware-coverage.md) | Freshness-aware coverage; per-topic refresh checks |
| [0007](0007-embedding-providers.md) | Embedding providers: Ollama locally, Voyage AI hosted |
| [0008](0008-web-frontend.md) | Web frontend in Vite, React, and TypeScript |
| [0009](0009-search-returns-only-relevant-hits.md) | Search returns only relevant hits |
| [0010](0010-worktrees-and-pull-requests.md) | One worktree and one pull request per task; CI on every PR |
| [0011](0011-one-hit-per-document.md) | One search hit per document, with `passages` |
| [0012](0012-unique-topics.md) | Topics are unique by normalized query; a repeated follow returns the existing topic (superseded by 0015) |
| [0013](0013-url-canonicalization-and-aliases.md) | Canonical URLs and aliases for exact duplicate content |
| [0014](0014-release-and-container.md) | Release build and app container |
| [0015](0015-remove-topics.md) | Remove the follow-topic feature; redesign it after news sources exist |
| [0016](0016-ollama-default-embeddings.md) | Ollama is the default embedding adapter, checked by a preflight |
| [0017](0017-live-fact-cards.md) | Live fact cards for entity queries: Wikidata identity, cache-only endpoint, background refresher |
| [0018](0018-ranking-prior.md) | Ranking prior: bounded log of Wikipedia page views, taken at ingest, applied after fusion |
| [0019](0019-license-agpl-3.md) | License: AGPL-3.0-only |
| [0020](0020-ci-hardening.md) | CI hardening: audits fail the build, migrations must roll back, separate jobs |
| [0021](0021-company-card-source.md) | Company card: facts from SEC EDGAR, price out of scope (no usable source of quotes) |
| [0022](0022-weather-card-terms-and-intent.md) | Weather card: Open-Meteo non-commercial terms and attribution, and a place has a weather card only for the weather intent |
| [0023](0023-rate-limiting-anonymous-endpoints.md) | Rate limiting for anonymous endpoints (per-client token bucket) and a fairness rule in the cache |
| [0024](0024-hnsw-iterative-scan.md) | Search: HNSW iterative scan (`strict_order`, `max_scan_tuples` 20,000) so dead index entries do not empty the vector list; pgvector 0.8 or later (superseded by 0030) |
| [0026](0026-per-document-license-fields.md) | Every document records its `license`, `attribution`, `modified` and `share`, set by its source at ingest; unknown means never shared |
| [0027](0027-wikimedia-concurrency-cap.md) | Wikimedia: at most 3 requests at once across Wikipedia and Wikidata, entity lookups first |
| [0028](0028-nba-card-source.md) | NBA card: balldontlie's free tier with a key per operator, replacing ESPN (whose terms forbid scripted access); no injuries |
| [0029](0029-wikibooks-source.md) | Wikibooks discovery source over a shared MediaWiki module, only for question-shaped queries; page views kept on Wikibooks' own scale |
| [0030](0030-sqlite-single-datastore.md) | SQLite as the single datastore: sqlite-vec (exact scan) for vectors, FTS5 with bm25 for full text, Oban Lite; one file per checkout, no Docker for development |
| [0031](0031-activity-record.md) | A local record of searches (written by an in-process recorder, a second exception to rule 6), the origin of each page, and the bytes discovery sources download; `GET /api/stats` |
| [0032](0032-crawl-allowlist-and-blocked-links.md) | Crawl allowlist in config (exact hosts); links to other hosts are logged in `blocked_links` (written by `Discovery`, not by the source), found through `extlinks` in the existing page request; a backfill job per indexed page |
| [0033](0033-background-crawl.md) | Background crawl (#89, in two PRs): while idle, read the links of the pages your searches showed, score them (interest x novelty, gap and shared-link bonuses) and keep the ones above a bar; preview mode is the default and fetches nothing, `on` fetches one page a minute (second PR); a supervised timer, not Oban cron |
