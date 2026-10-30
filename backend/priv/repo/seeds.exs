# Sample documents for a fresh dev database. Run with `mix run priv/repo/seeds.exs`
# (`make setup` runs it). Safe to run more than once: ingest is idempotent per URL.

for {url, title, body} <- [
      {"https://github.com/pgvector/pgvector", "pgvector",
       "pgvector is an open-source Postgres extension for vector similarity search. " <>
         "It supports exact and approximate nearest neighbor search with HNSW and IVFFlat indexes, " <>
         "and L2, inner product, and cosine distance."},
      {"https://hexdocs.pm/oban", "Oban",
       "Oban is a robust background job framework for Elixir, backed by PostgreSQL. " <>
         "It supports scheduled jobs, cron, unique jobs, retries with backoff, and queues with limits."},
      {"https://www.postgresql.org/docs/current/textsearch.html", "PostgreSQL full text search",
       "Full text search in PostgreSQL uses tsvector documents and tsquery queries. " <>
         "GIN indexes make @@ matches fast, and ts_rank orders results by relevance."}
    ] do
  {:ok, _} = Knowseek.Documents.ingest(%{url: url, title: title, body: body, source: "seed"})
end
