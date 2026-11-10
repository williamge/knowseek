import Config

# Configure your database
#
# One SQLite file per checkout (see config/dev.exs). The MIX_TEST_PARTITION
# environment variable adds a suffix (`mix help test`);
# scripts/check-migration-roundtrip sets DATABASE_PATH instead.
#
# Tests that use the database are not async: the SQL sandbox has one owner at
# a time, because SQLite has one writer and every transaction (the sandbox's
# too) starts IMMEDIATE (ADR 0030).
config :knowseek, Knowseek.Repo,
  database:
    System.get_env("DATABASE_PATH") ||
      Path.expand("../data/knowseek_test#{System.get_env("MIX_TEST_PARTITION")}.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :knowseek, KnowseekWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "gTqr1hg7IZsoVzaQKESX+bZ0JjEr2XOY0TJCA1V6NcDgM2j3Z/5D76QZl5e9Z+Qp",
  server: false

# Jobs are inserted but not run. Use Oban.Testing helpers to assert on them
# or perform them explicitly.
config :knowseek, Oban, testing: :manual

# Tests never need Ollama or the network: the adapter is Hashing unless a test
# switches it. Ollama and Voyage requests go to Req.Test stubs. Retries do not
# sleep.
config :knowseek, Knowseek.Embeddings, adapter: Knowseek.Embeddings.Hashing

config :knowseek, Knowseek.Embeddings.Ollama,
  req_options: [
    plug: {Req.Test, Knowseek.Embeddings.Ollama},
    retry_delay: 0,
    retry_log_level: false
  ]

config :knowseek, Knowseek.Cards.Balldontlie,
  api_key: "test-key",
  req_options: [plug: {Req.Test, Knowseek.Cards.Balldontlie}, retry: false]

config :knowseek, Knowseek.Cards.Edgar,
  req_options: [plug: {Req.Test, Knowseek.Cards.Edgar}, retry: false]

config :knowseek, Knowseek.Cards.OpenMeteo,
  req_options: [plug: {Req.Test, Knowseek.Cards.OpenMeteo}, retry: false]

# A failed NBA team list is refetched by the next request (no backoff), so a
# test can show that a bad answer is not cached as a success.
config :knowseek, Knowseek.Cards.Providers.Nba, teams_backoff: 0

config :knowseek, Knowseek.Embeddings.Voyage,
  api_key: "test-key",
  req_options: [
    plug: {Req.Test, Knowseek.Embeddings.Voyage},
    retry_delay: 0,
    retry_log_level: false
  ]

# Tests never call real sources. Tests that need one pass `sources:` to
# `Knowseek.Discovery.run/2`, and stub its HTTP calls with Req.Test.
config :knowseek, Knowseek.Discovery, sources: []

config :knowseek, Knowseek.Discovery.Sources.Wikipedia,
  req_options: [plug: {Req.Test, Knowseek.Discovery.Sources.Wikipedia}, retry: false]

config :knowseek, Knowseek.Discovery.Sources.Wikibooks,
  req_options: [plug: {Req.Test, Knowseek.Discovery.Sources.Wikibooks}, retry: false]

config :knowseek, Knowseek.Entities.Wikidata,
  req_options: [plug: {Req.Test, Knowseek.Entities.Wikidata}, retry: false]

# Tests of the limit turn it on and inject a limiter with a fake clock.
config :knowseek, KnowseekWeb.RateLimit, enabled: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
