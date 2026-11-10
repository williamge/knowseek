# Sample documents for a fresh dev database. Run with `mix run priv/repo/seeds.exs`
# (`make setup` runs it). Safe to run more than once: ingest is idempotent per URL.

for {url, title, body} <- [
      {"https://github.com/asg017/sqlite-vec", "sqlite-vec",
       "sqlite-vec is an SQLite extension for vector search. " <>
         "It stores float, int8 and binary vectors in vec0 virtual tables " <>
         "and finds nearest neighbors with L2, cosine or Hamming distance."},
      {"https://hexdocs.pm/oban", "Oban",
       "Oban is a robust background job framework for Elixir, backed by SQLite, PostgreSQL or MySQL. " <>
         "It supports scheduled jobs, cron, unique jobs, retries with backoff, and queues with limits."},
      {"https://www.sqlite.org/fts5.html", "SQLite FTS5",
       "FTS5 is an SQLite virtual table module that provides full-text search. " <>
         "MATCH queries find rows by terms, phrases and prefixes, and bm25 orders results by relevance."}
    ] do
  {:ok, _} = Knowseek.Documents.ingest(%{url: url, title: title, body: body, source: "seed"})
end
