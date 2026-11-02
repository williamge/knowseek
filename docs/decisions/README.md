# Architecture decision records

One file per decision: `NNNN-short-title.md`, numbered in order. Copy
`0000-template.md`. Do not edit an accepted ADR to change the decision;
write a new ADR that supersedes it and set the old one's status to
`Superseded by NNNN`.

| ADR | Decision |
| --- | --- |
| [0001](0001-elixir-phoenix-backend.md) | Elixir + Phoenix for the backend |
| [0002](0002-postgres-pgvector.md) | Postgres + pgvector as the single datastore |
| [0003](0003-hybrid-search.md) | Hybrid search with reciprocal rank fusion |
| [0004](0004-embeddings.md) | Pluggable embeddings, fixed at 1024 dimensions |
| [0005](0005-per-workspace-databases.md) | One database per Conductor workspace |
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
| [0023](0023-rate-limiting-anonymous-endpoints.md) | Rate limiting for anonymous endpoints (per-client token bucket) and a fairness rule in the cache |
