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
| [0014](0014-release-and-container.md) | Release build and app container |
